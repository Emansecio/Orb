import SwiftUI

// The hover texts of the controls whose action is not plain from their label, written once. A text that more than one
// control shows lives here (so the same action is never explained two ways), as does any text that carries a key: the
// key is read from `ShortcutCatalog`/`AppShortcut`, never typed by hand, so a key that changes changes its tip.
// A text only one control shows stays beside that control. The style, which the tests check on `Tip.all`:
// Brazilian Portuguese, one short sentence (about 80 characters at most), a present-tense verb or the effect, no full
// stop, the app's own words (Orb, contexto das conversas, comando de skill).

enum Tip {
    // MARK: Attachments

    static let attach = "Anexa arquivos ou escolhe uma skill; também dá para soltar arquivos ou digitar /"
    static let attachPictures = "Anexa imagens; também dá para colar ou soltar imagens na conversa"
    static let removeAttachment = "Tira o anexo desta mensagem"
    static let previewAttachment = "Abre a pré-visualização (Quick Look); arraste para levar o arquivo"
    static let previewImage = "Abre a imagem em pré-visualização (Quick Look)"
    static let missingAttachment = "O arquivo não está mais no lugar de antes"
    static let moreAttachments = "Mostra os outros anexos na pré-visualização"

    // MARK: Composer

    static let manageGrants = "Abre as liberações permanentes deste Orb no painel"
    static let adjustContext = "Abre Ajustes para escolher quanto das conversas o Orb guarda"
    static let chooseModel = "Escolhe o modelo da lista"
    static let forgetWindow = "Esquece o tamanho de janela aprendido para este modelo"
    static let suggestion = "Envia esta sugestão ao Orb"
    static let routineIdea = "Abre o editor de rotina já preenchido; nada é criado antes de salvar"
    static let queueAfterTask = "Deixa esta mensagem para depois da tarefa, em vez de entrar no próximo passo"
    static let steerNow = "Entrega esta mensagem ao Orb no próximo passo da tarefa"

    // MARK: Routines and scheduled tasks

    static let newRoutine = "Cria uma tarefa que o Orb faz sozinho, no horário"
    static let newRoutineCreatingAtlas = "Cria o Atlas, seu primeiro Orb, e abre o editor da rotina"
    static let newRoutineNeedingModel = "Leva a conectar um modelo; depois você volta e cria a rotina"
    static let routineTemplateCreatingAtlas = "Cria o Atlas, seu primeiro Orb, e abre o editor com este modelo"

    /// "Nova rotina" with no Orb yet: what the click will do.
    static func newRoutine(for start: RoutineStart) -> String {
        switch start {
        case .ready, .waiting: newRoutine
        case .createsAtlas: newRoutineCreatingAtlas
        case .needsModel: newRoutineNeedingModel
        }
    }

    /// A template card with no Orb yet.
    static func routineTemplate(for start: RoutineStart) -> String {
        switch start {
        case .ready, .waiting: routineTemplate
        case .createsAtlas: routineTemplateCreatingAtlas
        case .needsModel: newRoutineNeedingModel
        }
    }
    static let editRoutine = "Edita o horário e o pedido da rotina"
    static let deleteRoutine = "Apaga esta rotina e o histórico dela"
    static let runRoutineNow = "Roda a rotina agora, sem esperar o horário"
    static let runRoutineAgain = "Roda a rotina de novo, agora"
    static let queuedRoutine = "Roda assim que o Orb terminar o que está fazendo"
    static let routineConversation = "Abre a conversa em que a rotina rodou"
    static let copyReport = "Copia o relatório desta execução"
    static let openReportFile = "Abre o arquivo do relatório"
    static let runOnceNow = "Roda a rotina assim que for criada, para ver se funciona"
    static let cronExpression = "Cinco campos: minuto, hora, dia do mês, mês e dia da semana. Ex.: 0 9 * * 1-5 roda às 9h de segunda a sexta"
    static let routinePermissions = "Define como a rotina pede permissão, já que ninguém responde"
    static let allRoutines = "Abre a página Rotinas, com as de todos os Orbs"
    static func routineToggle(isOn: Bool) -> String { isOn ? "Pausa esta rotina" : "Ativa esta rotina" }
    static let routineDatePassed = "A data desta rotina já passou. Edite a data para ligar de novo"

    // MARK: Orb panel

    static let customizeOrb = "Muda cor, olhos, jeito e acessórios"
    static let refreshFolder = "Lê a pasta de novo"
    static let removeGrant = "Remove esta liberação; o Orb volta a perguntar"
    static let removeAllGrants = "Remove todas as liberações; o Orb volta a perguntar"
    static let recreateFolder = "Cria a pasta de novo, no mesmo lugar"
    static let changeFolder = "Escolhe outra pasta de trabalho para o Orb"
    static let manageConnectors = "Abre a página Conectores"
    static let cancelLogin = "Para de esperar o navegador; o login não é feito"
    static let macPermissions = "Abre os Ajustes de permissões do macOS"
    static let showInstructions = "Mostra o arquivo de instruções da pasta no Finder"
    static func openFolderInFinder(_ name: String) -> String { "Abre a pasta de \(name) no Finder" }
    static func openFolderInTerminal(_ name: String) -> String { "Abre o Terminal na pasta de \(name)" }
    static func toggleModelCard(isOpen: Bool) -> String { isOpen ? "Recolhe o modelo e o modo de permissão numa linha" : "Mostra o modelo e o modo de permissão" }
    static func toggleCapabilities(isOpen: Bool) -> String { isOpen ? "Recolhe o que o Orb pode usar numa linha" : "Mostra o que o Orb pode usar" }
    static func toggleBrowserOptions(isOpen: Bool) -> String { isOpen ? "Recolhe o navegador e a pesquisa" : "Mostra o navegador e a pesquisa" }
    /// What each switch of "Pode usar" does, in the hover text of its row (the panel keeps the rows short).
    static func capability(_ capability: Capability) -> String {
        switch capability {
        case .terminal: "Roda comandos e lê e escreve arquivos"
        case .browser: "Abre e lê páginas da internet"
        case .computerUse: "Abre, clica e preenche campos em outros apps"
        case .connectors: "Usa as ferramentas dos seus conectores"
        }
    }

    // MARK: Sidebar

    static let createFirstOrb = "Abre a folha para criar seu primeiro Orb"
    static let showWelcome = "Mostra a tela de boas-vindas"
    static let skillsPage = "Abre a página Skills"
    static let keptMemoryInFinder = "Mostra no Finder a memória que ficou guardada"
    static let dismissNotice = "Fecha este aviso"
    static let deleteWithMemory = "Apaga o Orb e também a memória dele; não volta"
    static let deleteKeepingMemory = "Apaga o Orb e guarda a memória em Memórias guardadas"
    static func profile(callName: String?) -> String { callName.map { "Abre o perfil de \($0) nos Ajustes" } ?? "Abre seu perfil nos Ajustes" }

    // MARK: Conversation

    static let copyReply = "Copia a resposta como texto"
    static let copyMarkdown = "Copia a resposta como Markdown"
    static let redoReply = "Descarta esta resposta e faz o pedido de novo"
    static let editMessage = "Põe esta mensagem no campo para editar; o que veio depois sai da conversa"
    static let cancelEdit = "Desiste da edição; o campo volta como estava"
    static func toggleOutput(isExpanded: Bool) -> String { isExpanded ? "Oculta o resultado desta ação" : "Mostra o resultado desta ação" }
    static func toggleCommand(isExpanded: Bool) -> String { isExpanded ? "Oculta o comando e o resultado desta ação" : "Mostra o comando e o resultado desta ação" }
    static func toggleWork(isOpen: Bool) -> String { isOpen ? "Recolhe o trabalho deste pedido numa linha" : "Mostra o que o Orb disse e fez neste pedido" }
    static func toggleActions(isOpen: Bool) -> String { isOpen ? "Recolhe estas ações numa linha" : "Mostra cada uma destas ações" }
    static func toggleRequest(isOpen: Bool) -> String { isOpen ? "Oculta os detalhes deste pedido" : "Mostra os detalhes deste pedido" }
    static let denyWithNote = "Recusa o pedido e diz ao Orb o que fazer no lugar"
    static let routineUseAuto = "Muda a rotina para Automático: só pergunta em ações destrutivas"
    static let routineUseReadOnly = "Muda a rotina para Só leitura: não altera nada no Mac"
    static let randomLook = "Sorteia cor, olhos e acessórios; o jeito fica"
    static let showAllActions = "Mostra todas as ações deste pedido"
    static let deny = "Recusa o pedido"
    static let allowOptions = "Permite só nesta tarefa ou sempre; remova depois em Liberações"
    static let handoffDone = "Você terminou no navegador: o Orb continua de onde parou"
    static let handoffCancel = "Você não vai fazer isso: o Orb segue sem esse passo"
    static let pickAnswer = "Responde com esta opção"
    static let quoteSelection = "Leva o trecho selecionado para a sua próxima mensagem, como citação"
    static let goToQuote = "Vai até o trecho citado na resposta do Orb"
    static let answerQuestion = "Envia o que você escreveu como resposta. Escrever no campo de mensagem também responde"
    static let answerInApp = "Abre a conversa para responder à pergunta"
    static let skipQuestion = "Deixa a pergunta sem resposta: o Orb segue com o que puder decidir sozinho"

    // MARK: Orb panel: browser
    static let removeBrowserProxy = "Tira o proxy do navegador deste Orb; as próximas páginas abrem direto"
    static let browserMode = "Segundo plano não abre janela nem tira o foco; Visível mostra o navegador do Orb"
    static let installBrowser = "Abre os Ajustes do navegador, onde está o comando de instalação"
    static let addSearchKey = "Abre os Ajustes do navegador, onde a chave do TinyFish é guardada"

    // MARK: Live screen of the Orb's browser
    static let enlargeScreen = "Mostra a tela do navegador do Orb maior, no painel"
    static let stopBrowsing = "Para o Orb: interrompe o que ele está fazendo"
    static let hideScreen = "Borra a tela do navegador até você mostrar de novo"
    static let revealScreen = "Mostra de novo a tela do navegador do Orb"
    static let lastScreen = "Mostra a última tela deste uso do navegador, enquanto o app estiver aberto"
    static let backToLiveScreen = "Volta para a tela ao vivo do navegador do Orb"
    static let showBrowserScreen = "Mostra no chat a página que o Orb abre no navegador, ao vivo; nada é gravado"

    // MARK: Menu bar panel

    static let menuBarItem = "Abre o painel rápido do Orb, sem abrir o app"
    static let connectModel = "Abre os Ajustes para conectar um modelo"
    static let openMainWindow = "Abre a janela principal do Orb"
    static let closeReply = "Fecha esta resposta no painel"
    static let openChatInApp = "Abre esta conversa na janela principal"
    static let reviewRiskyInApp = "Abre o app para você revisar esta ação arriscada"
    static let allowOnce = "Permite esta ação só desta vez"
    static let allowBatchOnce = "Permite todas estas ações, só desta vez"
    static let routineRequest = "Abre a conversa da rotina, onde está o pedido de permissão"
    static let sendToBackground = "Deixa o comando rodando em segundo plano e volta a conversa com o Orb (\(AppShortcut.sendToBackground.label)). Mandar uma mensagem com o comando rodando há mais de 3 segundos faz o mesmo"
    static func chooseOrb(named name: String) -> String { "Escolhe \(name) para receber a mensagem" }

    // MARK: Import

    static let importFromAssistant = "Traz outro assistente ou um bot do marketplace do Grok Bot para o novo Orb"
    static let startFromKeptMemory = "Começa o Orb a partir da memória guardada de um Orb apagado"
    static let importBack = "Volta à criação do Orb, sem importar"
    static let importCopyPrompt = "Copia o prompt para você colar no outro assistente"
    static let importChooseFile = "Escolhe o arquivo ou a pasta que o outro assistente exportou"
    static let importSource = "Escolhe entre outro assistente e um bot do marketplace do Grok Bot"
    static let importOpenMarketplace = "Abre o marketplace do Grok Bot no navegador"
    static let importPickBot = "Lê este bot e mostra o que vem dele na prévia"
    static let importMarketplaceCategory = "Mostra só os bots desta categoria do marketplace"
    static let importReadLocal = "Lê as configurações deste assistente que estão neste Mac"
    static let importKind = "Diz se o texto são instruções do assistente ou lembranças sobre você"
    static let importItem = "Marcado, este item vai para o novo Orb"
    static let importReview = "Volta à prévia para marcar ou desmarcar itens"
    static let importRemove = "Descarta a importação; o Orb é criado sem ela"
    static func importToggleSkill(isShowing: Bool) -> String { isShowing ? "Oculta as instruções desta skill" : "Mostra as instruções desta skill" }

    // MARK: Skills and catalogs

    static let newSkill = "Cria uma skill sua, com comando e instruções"
    static let noOrbForSkill = "Nenhum Orb pode usar esta skill"
    static let installed = "Instalada"
    static let openSkillDetails = "Abre os detalhes e as instruções desta skill"
    static let discardProposal = "Descarta a proposta do Orb; ela não é salva"
    static let keepProposal = "Fecha sem decidir; a proposta continua esperando"
    static let saveProposal = "Instala a skill para os Orbs poderem usá-la"
    static let clearSearch = "Limpa a busca"
    static let showInstalled = "Mostra o que já está instalado"
    static let showCatalog = "Procura no catálogo aberto"
    static let showGallery = "Mostra os serviços que se conectam com um clique"
    static func useSkill(orb: String, slug: String) -> String { "Abre a conversa com \(orb) com /\(slug) pronto" }
    static func chooseOrbForSkill(slug: String) -> String { "Escolhe o Orb que vai usar /\(slug)" }
    static func copySlug(_ slug: String) -> String { "Copia /\(slug) para colar numa mensagem" }
    static func skillToggle(isOn: Bool) -> String { isOn ? "Desativa a skill; ela fica instalada, mas ninguém a usa" : "Ativa a skill para os Orbs usarem" }
    static func moreOptions(of name: String) -> String { "Mais opções de \(name)" }
    static func searchFor(_ term: String) -> String { "Busca por “\(term)”" }

    // MARK: Memory

    static let memoryShowKind = "Mostra tudo o que há neste tipo de memória"
    static let memoryShowAll = "Abre a lista completa do que o Orb lembra, com busca"
    static let memoryFolder = "Abre no Finder a pasta com os arquivos .md da memória"
    static let memoryHow = "Explica como o Orb guarda e usa o que aprende"
    static let editIdentity = "Edita as notas de como o Orb funciona, que vão em toda conversa"
    static let forget = "Esquece isto; dá para desfazer por alguns segundos"
    static let expandMemory = "Expande esta lembrança"
    static let collapseMemory = "Recolhe esta lembrança"
    static func restartInterview(_ name: String) -> String { "Na próxima conversa, \(name) faz perguntas para entender como ajudar você" }

    // MARK: Welcome and first use

    static let createAtlas = "Cria o Atlas agora; dá para personalizar depois"
    static let startWithClaudeCode = "Conecta o Claude Code e cria o Atlas, seu primeiro Orb"
    static func otherWaysToConnect(isShowing: Bool) -> String {
        "\(isShowing ? "Esconde" : "Mostra") os outros caminhos para conectar um modelo"
    }
    static let allKeptMemories = "Abre a folha Novo Orb com todas as memórias guardadas"
    static let continueFromMemory = "Cria um Orb a partir desta memória guardada"
    static let modelSettings = "Abre os Ajustes de provedores e modelos"
    static let useClaudeCode = "Usa o Claude Code que já está conectado neste Mac"
    static let signInClaudeCode = "Abre o navegador para entrar com sua conta do Claude"
    static let signInChatGPT = "Abre o navegador para entrar com sua assinatura do ChatGPT"
    static let pasteKey = "Conecta com uma chave de API que você cola"
    static let stopConnecting = "Para a tentativa de conexão"
    static let retryConnecting = "Tenta conectar de novo"
    static func useLocalServer(_ name: String) -> String { "Usa o \(name) que já roda neste Mac, sem enviar nada para fora" }
    static func createOrbSheet() -> String { "Abre a folha para criar um Orb (\(AppShortcut.newBot.label))" }

    // MARK: Ajustes

    static let launchAtLogin = "Abre o Orb sozinho quando você entra no Mac"
    static let openLoginItems = "Abre Itens de Início, nos Ajustes do Sistema, onde o Orb espera a sua aprovação"
    static let notifyWhenDone = "Mostra uma notificação quando um Orb termina ou precisa de você"
    static let proposeSkills = "Deixa o Orb propor skills; nada é salvo sem a sua aprovação"
    static let summarizeSessions = "Pede ao modelo um resumo das conversas longas guardadas; uma chamada curta por conversa"
    static let reviewDictation = "Corrige o texto ditado com o modelo do Orb antes de você enviar"
    static let orbsCanTalk = "Deixa os Orbs pedirem ajuda uns aos outros; Parar interrompe a conversa toda"
    static let orbsCanStartGroups = "Deixa um Orb criar um grupo ou pedir a um grupo dele quando você pede no chat"
    static let dataFolder = "Mostra no Finder a pasta com conversas, memórias e ajustes"
    static let keptMemoriesFolder = "Mostra no Finder as memórias guardadas de Orbs apagados"
    static let orbsFolder = "Mostra no Finder a pasta onde ficam as pastas dos Orbs"
    static let resetOrb = "Abre a folha para voltar o Orb ao primeiro uso; você confirma antes"
    static let openSystemNotifications = "Abre os Ajustes do Sistema para liberar as notificações do Orb"
    static let askNotifications = "Pede ao macOS licença para o Orb enviar notificações"
    static let globalShortcut = "Liga o atalho global; se outro app já usa essas teclas, ele fica desligado"

    static let profilePhotoAvatar = "Escolhe uma imagem para o perfil, ou arraste uma para cá"
    static let profilePhotoChoose = "Escolhe uma imagem do Mac; a foto fica só neste Mac"
    static let profilePhotoRemove = "Tira a foto do perfil; voltam as iniciais"

    // MARK: Providers

    static let addProvider = "Conecta mais um provedor de modelos"
    static let refreshModels = "Busca no provedor a lista atual de modelos"
    static let removeProvider = "Remove o provedor e a chave; Orbs com esses modelos passam a usar o padrão"
    static let signOutChatGPT = "Desconecta sua conta do ChatGPT neste Mac"
    static let replaceKey = "Troca a chave de API guardada no Keychain"
    static let deleteKey = "Apaga a chave guardada no Keychain; o provedor continua na lista"
    static let saveKey = "Guarda a chave no Keychain deste Mac"
    static let keepKey = "Mantém a chave que já está salva"
    static let getKey = "Abre a página do provedor onde a chave é criada"
    static let listAllModels = "Abre a lista com todos os modelos deste provedor"
    static let addModelByID = "Adiciona o modelo digitado à lista deste provedor"
    static let removeModelFromList = "Tira este modelo da lista; o provedor não muda"
    static let gatewayFormat = "Escolhe o formato de API que o seu gateway entende"
    static let checkClaudeCode = "Procura o Claude Code de novo neste Mac"
    static let installClaudeCode = "Abre a página com as instruções de instalação"
    static let signOutClaudeCode = "Desconecta o Claude Code neste Mac, inclusive no Terminal"

    // MARK: Usage, permissions, reset

    static let usagePeriod = "Escolhe o período do gasto"
    static let usageChartBy = "Pinta o gráfico por Orb ou por modelo"
    static let priceCorrected = "Preço corrigido por você; clique para mudar"
    static let priceCorrect = "Corrige o preço deste modelo"
    static let priceMissing = "Informa o preço deste modelo para calcular o custo"
    static let priceRestore = "Volta ao preço original do modelo"
    static let copyCode = "Copia este trecho de código"
    static let copyCommand = "Copia este comando"
    static let copyOutput = "Copia o resultado desta ação"
    static let recheckPermissions = "Lê de novo o estado das permissões do macOS"
    static let resetConfirm = "Pede a confirmação final antes de apagar"
    static func permissionAction(_ action: PermissionRowAction) -> String {
        switch action {
        case .ask: "Pede esta permissão ao macOS"
        case .openAppAndAsk(let name): "Abre \(name) e pede a permissão a ele"
        case .openSystemSettings: "Abre os Ajustes do Sistema nesta permissão"
        case .test: "Usa a permissão de verdade, só olhando, para ver se funciona"
        case .relaunch: "Fecha e abre o Orb de novo para o macOS aplicar a permissão"
        }
    }

    // MARK: Odds and ends

    static let autoColor = "Usa uma cor que combina com a do corpo do Orb"
    static let routineTemplate = "Abre o editor de rotina já preenchido com este modelo"
    static let openRunReport = "Abre o relatório desta execução"
    static let findResults = "Mostra a lista dos resultados, com um trecho de cada"
    static let findClose = "Fecha a busca"
    static let exploreSkills = "Abre a busca no catálogo aberto de skills"
    static let showProviderDetails = "Mostra a chave, o endereço e os modelos deste provedor"
    static let hideProviderDetails = "Esconde os detalhes deste provedor"
    static func previewActivity(_ label: String) -> String { "Mostra o Orb em atividade: \(label)" }

    // MARK: With a key

    static func newBot() -> String { "Cria um novo Orb (\(AppShortcut.newBot.label))" }
    static let newOrbOrCategory = "Cria um Orb ou uma categoria"
    static func newGroup() -> String { "Junta Orbs para trabalharem juntos num pedido (\(AppShortcut.newGroup.label))" }
    static func settings() -> String { "Abre os Ajustes (\(AppShortcut.settings.label))" }
    static func findInConversation() -> String { "Busca nesta conversa (\(AppShortcut.find.label))" }
    static func findNext() -> String { "Vai para o próximo resultado (\(AppShortcut.findNext.label))" }
    static func findPrevious() -> String { "Vai para o resultado anterior (\(AppShortcut.findPrevious.label))" }
    static func inspector(isShowing: Bool) -> String { "\(isShowing ? "Oculta" : "Mostra") o painel do Orb (\(AppShortcut.toggleInspector.label))" }

    /// A sentence of the app's own prose, as the tail of a tip: no full stop at the end.
    static func withoutFullStop(_ text: String) -> String { text.hasSuffix(".") ? String(text.dropLast()) : text }

    /// Every fixed text above, for the test that holds them to the style. Three are left out on purpose, for being more
    /// than one sentence or longer than 90 characters: `cronExpression`, `sendToBackground` and `answerQuestion`.
    /// (A test reads this file and fails for any other tip that is not listed.)
    static var all: [String] {
        [attach, attachPictures, removeAttachment, previewAttachment, previewImage, missingAttachment, moreAttachments,
         manageGrants, adjustContext, chooseModel, forgetWindow, suggestion, routineIdea, queueAfterTask, steerNow,
         newRoutine, editRoutine, deleteRoutine, runRoutineNow, runRoutineAgain, queuedRoutine, routineConversation,
         copyReport, openReportFile, runOnceNow, routinePermissions, allRoutines,
         routineToggle(isOn: true), routineToggle(isOn: false), routineDatePassed,
         customizeOrb, refreshFolder, removeGrant, removeAllGrants, recreateFolder, changeFolder, manageConnectors, cancelLogin,
         macPermissions, showInstructions, openFolderInFinder("Orb"), openFolderInTerminal("Orb"),
         toggleModelCard(isOpen: true), toggleModelCard(isOpen: false), toggleCapabilities(isOpen: true), toggleCapabilities(isOpen: false),
         toggleBrowserOptions(isOpen: true), toggleBrowserOptions(isOpen: false),
         capability(.terminal), capability(.browser), capability(.computerUse), capability(.connectors),
         createFirstOrb, showWelcome, skillsPage, keptMemoryInFinder, dismissNotice, deleteWithMemory,
         deleteKeepingMemory, profile(callName: "Ana"), profile(callName: nil),
         copyReply, copyMarkdown, redoReply, editMessage, cancelEdit, toggleOutput(isExpanded: true), toggleOutput(isExpanded: false), toggleCommand(isExpanded: true), toggleCommand(isExpanded: false), toggleRequest(isOpen: true), toggleRequest(isOpen: false), toggleActions(isOpen: true), toggleActions(isOpen: false), toggleWork(isOpen: true), toggleWork(isOpen: false),
         routineUseAuto, routineUseReadOnly, randomLook, denyWithNote, showAllActions, deny, allowOptions,
         handoffDone, handoffCancel, browserMode, removeBrowserProxy, installBrowser, addSearchKey,
         enlargeScreen, stopBrowsing, hideScreen, revealScreen, lastScreen, backToLiveScreen, showBrowserScreen,
         menuBarItem, connectModel, openMainWindow, closeReply, openChatInApp, reviewRiskyInApp, allowOnce, allowBatchOnce,
         routineRequest, chooseOrb(named: "Orb"),
         importFromAssistant, importPickBot, importMarketplaceCategory, startFromKeptMemory, importBack, importCopyPrompt, importChooseFile, importReadLocal, importKind, importItem, importReview, importRemove,
         importToggleSkill(isShowing: true), importToggleSkill(isShowing: false),
         newSkill, noOrbForSkill, installed, openSkillDetails, discardProposal, keepProposal, saveProposal, clearSearch,
         showInstalled, showCatalog, showGallery, useSkill(orb: "Orb", slug: "resumir"), chooseOrbForSkill(slug: "resumir"),
         copySlug("resumir"), skillToggle(isOn: true), skillToggle(isOn: false), moreOptions(of: "Orb"), searchFor("pdf"),
         memoryShowKind, memoryShowAll, memoryFolder, memoryHow, editIdentity, forget, expandMemory, collapseMemory,
         restartInterview("Orb"),
         createAtlas, startWithClaudeCode, otherWaysToConnect(isShowing: true), otherWaysToConnect(isShowing: false),
         newRoutineCreatingAtlas, newRoutineNeedingModel, routineTemplateCreatingAtlas, allKeptMemories, continueFromMemory, modelSettings, useClaudeCode, signInClaudeCode, signInChatGPT,
         pasteKey, stopConnecting, retryConnecting, useLocalServer("Ollama"), createOrbSheet(),
         launchAtLogin, openLoginItems, notifyWhenDone, proposeSkills, summarizeSessions, reviewDictation, orbsCanTalk, orbsCanStartGroups, dataFolder, keptMemoriesFolder, orbsFolder, resetOrb,
         openSystemNotifications, askNotifications, globalShortcut,
         profilePhotoAvatar, profilePhotoChoose, profilePhotoRemove,
         addProvider, refreshModels, removeProvider, signOutChatGPT, replaceKey, deleteKey, saveKey, keepKey, getKey, listAllModels,
         addModelByID, removeModelFromList, gatewayFormat, checkClaudeCode, installClaudeCode, signOutClaudeCode,
         usagePeriod, usageChartBy, priceCorrected, priceCorrect, priceMissing, priceRestore, copyCode, copyCommand, copyOutput,
         recheckPermissions, resetConfirm,
         autoColor, routineTemplate, openRunReport, exploreSkills, showProviderDetails, hideProviderDetails,
         previewActivity("pensando"),
         findResults, findClose, findInConversation(), findNext(), findPrevious(),
         newBot(), newOrbOrCategory, newGroup(), settings(), inspector(isShowing: true), inspector(isShowing: false),
         pickAnswer, quoteSelection, goToQuote, answerInApp, skipQuestion,
         importSource, importOpenMarketplace,
         permissionAction(.ask), permissionAction(.openAppAndAsk(appName: "Notas")), permissionAction(.openSystemSettings),
         permissionAction(.test), permissionAction(.relaunch)]
    }
}

extension View {
    /// A hover text on a control that is only an icon: the same short text is its VoiceOver label, so the person who
    /// cannot see the icon hears what the person who hovers reads. (A control with a text label uses `.help` alone.)
    func iconTip(_ text: String, label: String? = nil) -> some View {
        help(text).accessibilityLabel(label ?? text)
    }
}
