import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Type } from "@earendil-works/pi-ai";
import { defineTool, type ExtensionAPI, type ExtensionContext } from "@earendil-works/pi-coding-agent";

const here = dirname(fileURLToPath(import.meta.url));
const script = join(here, "win.ps1");
let allowAll = false;

// Arguments travel in an env var so model text is never spliced into a command line.
function runWin(action: string, args: object, signal?: AbortSignal): Promise<any> {
	return new Promise((resolve, reject) => {
		execFile(
			"powershell.exe",
			["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-Action", action],
			{
				env: { ...process.env, PCKIT_ARGS: JSON.stringify(args) },
				signal,
				timeout: 60_000,
				maxBuffer: 16 * 1024 * 1024,
				windowsHide: true,
			},
			(err, stdout, stderr) => {
				const last = stdout.trim().split(/\r?\n/).pop() ?? "";
				let data: any;
				try {
					data = last ? JSON.parse(last) : undefined;
				} catch {}
				if (data?.error) return reject(new Error(data.error));
				if (err || data === undefined) return reject(new Error((stderr || err?.message || "Sem resposta do PowerShell.").trim()));
				resolve(data);
			},
		);
	});
}

async function approve(ctx: ExtensionContext, what: string) {
	if (allowAll || !ctx.hasUI) return;
	const choice = await ctx.ui.select(`Permitir ação no PC? ${what}`, ["Permitir", "Permitir tudo nesta sessão", "Negar"]);
	if (choice === "Permitir tudo nesta sessão") allowAll = true;
	else if (choice !== "Permitir") throw new Error("O usuário negou esta ação.");
}

const text = (t: string, details?: unknown) => ({ content: [{ type: "text" as const, text: t }], details });

const windowParam = Type.String({ description: "Parte do título da janela ou o handle numérico retornado por ui_windows." });
const elementParams = {
	name: Type.Optional(Type.String({ description: "Nome/texto do elemento (igual ou contido), como aparece em ui_tree." })),
	automationId: Type.Optional(Type.String({ description: "AutomationId exato (o id= em ui_tree)." })),
	controlType: Type.Optional(Type.String({ description: "Tipo do controle: Button, Edit, MenuItem, CheckBox, ListItem, TabItem, Hyperlink..." })),
	index: Type.Optional(Type.Number({ description: "Qual ocorrência usar quando há várias (começa em 0)." })),
};

const uiWindows = defineTool({
	name: "ui_windows",
	label: "Janelas abertas",
	description: "Lista as janelas abertas no Windows com título, processo e handle.",
	promptSnippet: "ui_windows: lista janelas abertas do Windows",
	promptGuidelines: [
		"Para mexer em programas do Windows: ui_windows → ui_tree → ui_click / ui_set_value / ui_type, e confira o resultado com ui_tree ou pc_screenshot.",
		"Para sites, prefira as ferramentas do navegador Playwright (mcp__playwright__*) em vez de clicar no navegador com ui_click.",
		"Neste Windows, prefira a ferramenta powershell para comandos de sistema.",
	],
	parameters: Type.Object({}),
	annotations: { readOnlyHint: true },
	async execute(_id, _params, signal) {
		const data = await runWin("windows", {}, signal);
		const lines = data.windows.map((w: any) => `${w.handle}  ${w.process}  "${w.title}"`);
		return text(lines.join("\n") || "Nenhuma janela.", data);
	},
});

const uiTree = defineTool({
	name: "ui_tree",
	label: "Controles da janela",
	description: "Mostra a árvore de controles (botões, campos, menus) de uma janela, com nomes e ids para usar em ui_click, ui_set_value e ui_type.",
	parameters: Type.Object({
		window: windowParam,
		depth: Type.Optional(Type.Number({ description: "Profundidade máxima (padrão 6)." })),
		maxNodes: Type.Optional(Type.Number({ description: "Máximo de linhas (padrão 400)." })),
	}),
	annotations: { readOnlyHint: true },
	async execute(_id, params, signal) {
		const data = await runWin("tree", params, signal);
		const note = data.truncated ? "\n[cortado: aumente maxNodes ou depth para ver mais]" : "";
		return text(`Janela ${data.window.handle} "${data.window.title}"\n${data.tree}${note}`, data.window);
	},
});

const uiClick = defineTool({
	name: "ui_click",
	label: "Clicar",
	description:
		"Clica num controle de uma janela (pelo nome, automationId ou tipo) ou num ponto da tela (x, y em pixels da tela). Usa a ação nativa do controle quando existe e o mouse quando não.",
	parameters: Type.Object({
		window: Type.Optional(windowParam),
		...elementParams,
		x: Type.Optional(Type.Number({ description: "X na tela. Use junto com y em vez de identificar o elemento." })),
		y: Type.Optional(Type.Number({ description: "Y na tela." })),
		button: Type.Optional(Type.Union([Type.Literal("left"), Type.Literal("right")])),
		double: Type.Optional(Type.Boolean({ description: "Clique duplo." })),
		mouse: Type.Optional(Type.Boolean({ description: "Forçar clique real com o mouse." })),
	}),
	async execute(_id, params, signal, _onUpdate, ctx) {
		const target = params.x !== undefined ? `ponto (${params.x}, ${params.y})` : `${params.name ?? params.automationId ?? params.controlType} em "${params.window}"`;
		await approve(ctx, `clicar em ${target}`);
		const data = await runWin("click", params, signal);
		return text(`Clique feito (${data.method})${data.element ? `: ${data.element}` : ""}`, data);
	},
});

const uiSetValue = defineTool({
	name: "ui_set_value",
	label: "Preencher campo",
	description: "Escreve um valor diretamente num campo de texto de uma janela, sem depender do foco do teclado.",
	parameters: Type.Object({ window: windowParam, ...elementParams, value: Type.String() }),
	async execute(_id, params, signal, _onUpdate, ctx) {
		await approve(ctx, `preencher ${params.name ?? params.automationId ?? params.controlType} em "${params.window}"`);
		const data = await runWin("set_value", params, signal);
		return text(`Valor definido: ${data.element}`, data);
	},
});

const uiType = defineTool({
	name: "ui_type",
	label: "Digitar",
	description:
		"Traz a janela para frente e digita no teclado. 'text' é digitado literalmente (quebra de linha vira Enter). 'keys' usa a sintaxe SendKeys para atalhos: ^c = Ctrl+C, %{F4} = Alt+F4, {ENTER}, {TAB}, {ESC}.",
	parameters: Type.Object({
		window: Type.Optional(windowParam),
		...elementParams,
		text: Type.Optional(Type.String()),
		keys: Type.Optional(Type.String()),
	}),
	async execute(_id, params, signal, _onUpdate, ctx) {
		const preview = [params.text && `"${params.text.slice(0, 60)}"`, params.keys].filter(Boolean).join(" + ");
		await approve(ctx, `digitar ${preview}${params.window ? ` em "${params.window}"` : ""}`);
		await runWin("type", params, signal);
		return text("Digitado.");
	},
});

const uiFocus = defineTool({
	name: "ui_focus",
	label: "Trazer janela",
	description: "Restaura e traz uma janela para a frente.",
	parameters: Type.Object({ window: windowParam }),
	async execute(_id, params, signal) {
		const data = await runWin("focus", params, signal);
		return text(`Janela em foco: "${data.window.title}"`, data.window);
	},
});

const pcScreenshot = defineTool({
	name: "pc_screenshot",
	label: "Print da tela",
	description:
		"Tira um print da tela inteira ou de uma janela e devolve a imagem. Só é útil se o modelo atual aceitar imagens; caso contrário use ui_tree.",
	parameters: Type.Object({
		window: Type.Optional(windowParam),
		maxWidth: Type.Optional(Type.Number({ description: "Largura máxima da imagem (padrão 1600)." })),
	}),
	annotations: { readOnlyHint: true },
	async execute(_id, params, signal) {
		const d = await runWin("screenshot", params, signal);
		const data = readFileSync(d.path).toString("base64");
		const info =
			`Print salvo em ${d.path} (${d.width}x${d.height}). ` +
			`Para clicar num ponto (px, py) da imagem com ui_click use x = ${d.left} + px / ${d.scale}, y = ${d.top} + py / ${d.scale}.`;
		return { content: [{ type: "text" as const, text: info }, { type: "image" as const, data, mimeType: "image/jpeg" }], details: d };
	},
});

export default function (pi: ExtensionAPI) {
	const require = createRequire(import.meta.url);
	let playwrightCli: string | undefined;
	try {
		playwrightCli = join(dirname(require.resolve("@playwright/mcp/package.json")), "cli.js");
	} catch {}
	if (playwrightCli) {
		pi.registerMcpServer("playwright", {
			command: process.execPath,
			args: [playwrightCli, "--browser", "msedge"],
			exposure: "direct",
			description: "Navegador Microsoft Edge controlado pelo agente: abrir sites, ler a página, clicar, preencher e tirar prints.",
		});
	}

	if (process.platform === "win32") {
		for (const tool of [uiWindows, uiTree, uiClick, uiSetValue, uiType, uiFocus, pcScreenshot]) pi.registerTool(tool);
	}

	pi.on("session_start", async (_event, ctx) => {
		allowAll = false;
		if (process.platform === "win32") pi.setActiveTools([...new Set([...pi.getActiveTools(), "powershell"])]);
		if (!playwrightCli && ctx.hasUI) ctx.ui.notify("pi-pc-kit: @playwright/mcp não foi instalado; o navegador está indisponível.", "warning");
	});
}
