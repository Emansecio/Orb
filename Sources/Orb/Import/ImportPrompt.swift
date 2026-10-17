import Foundation

/// The prompt the person pastes into the assistant they are leaving. Its answer, the "Cartão do Orb", is what
/// `OrbImportReader` reads best; any other shape still works (see the reader). Keep the headings here and in the reader
/// the same: a test reads an answer written exactly as this asks.
enum ImportPrompt {
    static let text = """
    Estou mudando para outro assistente e quero levar o que você sabe sobre mim e como trabalha comigo. Responda com UM único bloco de código Markdown, sem nada antes nem depois, neste formato exato (títulos em português, como abaixo):

    # Orb: <o nome deste assistente, ou o nome do GPT, Gem ou Projeto>
    Papel: <uma frase: o que ele faz por mim>
    Origem: <o seu nome, por exemplo ChatGPT, Gemini, Claude ou Copilot>

    ## Como funciona
    Instruções e personalidade que você segue comigo, em tópicos curtos (no máximo 1.200 caracteres). Se você é um GPT, Gem ou Projeto, copie aqui as instruções dele.

    ## Preferências
    - Como prefiro que você responda ou trabalhe (até 12 itens, uma linha cada).

    ## Sobre mim
    - Fatos duradouros sobre mim e meu trabalho (até 40 itens, uma linha cada, com a data entre parênteses quando souber).

    ## Procedimentos
    ### <nome de uma tarefa que se repete (se for em horário fixo, escreva o horário no título)>
    Os passos que costumamos seguir (até 5 procedimentos).

    ## Skills
    ### /comando: o que faz
    Instruções para executar, só de tarefas que pedi mais de uma vez (até 5).

    Regras: use só o que você realmente sabe sobre mim; não invente nem complete lacunas; se não souber, deixe a seção vazia. Não inclua senhas, chaves de API, tokens, documentos, dados bancários nem informações sobre outras pessoas. Cada item deve fazer sentido sozinho, sem depender desta conversa.
    """
}
