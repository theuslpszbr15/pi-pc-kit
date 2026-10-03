# pi-pc-kit

Pacote para o [Pi](https://pi.dev) que deixa o agente usar o navegador e o seu Windows de verdade.

| O que vem | Para que serve |
| --- | --- |
| Playwright MCP (Microsoft Edge) | Abrir sites, ler a página, clicar, preencher, tirar print |
| `ui_windows`, `ui_tree`, `ui_focus` | Ver janelas abertas e os botões/campos de cada uma |
| `ui_click`, `ui_set_value`, `ui_type` | Clicar, preencher campos, digitar e usar atalhos em qualquer programa |
| `pc_screenshot` | Print da tela ou de uma janela (para modelos que aceitam imagem) |
| Ferramenta `powershell` | Ativada automaticamente no Windows |
| Skill `controle-do-pc` | Ensina o agente o passo a passo e as regras de segurança |

Antes de clicar, preencher ou digitar, o Pi pergunta: **Permitir**, **Permitir tudo nesta sessão** ou **Negar**.

## Instalar

Requisitos: Windows 10/11, Pi 1.x e [Git for Windows](https://git-scm.com/download/win).

```powershell
winget install --id Git.Git -e
```

Feche e abra o PowerShell, depois:

```powershell
pi install git:github.com/theuslpszbr15/pi-pc-kit
```

Abra o `pi`. O `/mcp` deve mostrar o servidor `playwright` conectado.

### Atualizar e remover

```powershell
pi update --extensions
pi remove git:github.com/theuslpszbr15/pi-pc-kit
```

## Usar modelos grátis da NVIDIA

1. Crie uma chave em [build.nvidia.com](https://build.nvidia.com) (começa com `nvapi-`).
2. No Pi: `/login` → **Sign in with an API key** → **NVIDIA** → cole a chave.
3. Se o `/model` não listar modelos da NVIDIA, crie `%USERPROFILE%\.pi\agent\models.json`:

```json
{
  "providers": {
    "nvidia": {
      "baseUrl": "https://integrate.api.nvidia.com/v1",
      "api": "openai-completions",
      "models": [{ "id": "nvidia/nemotron-3-ultra-550b-a55b" }]
    }
  }
}
```

Use modelos com suporte a *tool calling*; sem isso o agente não consegue usar as ferramentas.

## Exemplos de pedidos

- "Abre o Bloco de Notas e escreve uma lista de compras."
- "Entra no site da previsão do tempo e me diz se vai chover amanhã."
- "Abre as Configurações do Windows e me mostra quanto espaço tem no disco."

## Segurança

O agente age no seu PC real com as suas permissões. Leia o que ele pede antes de permitir, não deixe ele digitar senhas por você e use **Permitir tudo nesta sessão** só em tarefas que você está acompanhando. Prints ficam em `%TEMP%\pi-pc-kit`.

## Licença

MIT
