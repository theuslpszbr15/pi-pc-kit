---
name: controle-do-pc
description: Como controlar o computador Windows do usuário — abrir programas, clicar em botões, preencher campos, digitar, tirar prints e navegar em sites pelo Edge. Use quando o pedido envolver mexer em janelas, apps instalados, configurações do Windows ou páginas web.
---

# Controle do PC

Você roda no Windows do usuário e pode agir de verdade nele. Toda ação muda o PC real, então trabalhe com cuidado e confira o resultado.

## Escolha a ferramenta certa

| Tarefa | Use |
| --- | --- |
| Comandos, arquivos, instalar/abrir programas | `powershell` |
| Sites e aplicações web | Ferramentas `mcp__playwright__*` (Edge controlado) |
| Programas de janela (Bloco de Notas, Configurações, apps) | `ui_windows`, `ui_tree`, `ui_click`, `ui_set_value`, `ui_type` |
| Ver a tela | `pc_screenshot` (só se o modelo aceitar imagem); senão `ui_tree` |

## Fluxo para programas de janela

1. Abra o programa com `powershell` (`Start-Process notepad`) se ainda não estiver aberto.
2. `ui_windows` para achar o título ou o handle da janela.
3. `ui_tree` nessa janela para ver os controles. Use os nomes e `id=` exatamente como aparecem.
4. Aja:
   - Botões, menus, abas, caixas de seleção: `ui_click` com `name` ou `automationId`.
   - Campos de texto: `ui_set_value`. Se o campo recusar, `ui_click` nele e depois `ui_type`.
   - Atalhos: `ui_type` com `keys` (`^s` salva, `^a` seleciona tudo, `{ENTER}`, `%{F4}` fecha).
5. Rode `ui_tree` (ou `pc_screenshot`) de novo para confirmar que funcionou antes de dizer que terminou.

Se vários elementos tiverem o mesmo nome, filtre por `controlType` ou escolha com `index`.

## Fluxo para sites

1. `mcp__playwright__browser_navigate` para abrir a URL.
2. `mcp__playwright__browser_snapshot` para ler a página e pegar as referências dos elementos.
3. Clique e preencha usando as referências do snapshot.
4. Faça um novo snapshot para confirmar.

Logins, senhas, códigos de verificação e pagamentos são do usuário: pare e peça para ele fazer essa parte.

## Regras de segurança

- Antes de apagar arquivos, desinstalar programas, mudar configurações do sistema ou enviar mensagens/e-mails em nome do usuário, explique o que vai fazer e peça confirmação.
- Não leia nem mostre senhas, tokens ou chaves que aparecerem na tela ou em arquivos.
- Não desative antivírus, firewall ou o Controle de Conta de Usuário.
- Se uma janela pedir permissão de administrador, avise o usuário: só ele pode aprovar.
