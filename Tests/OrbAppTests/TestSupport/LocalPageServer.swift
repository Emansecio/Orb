import Foundation
import Network

/// A web server on `127.0.0.1` for the tests of real browsers: a few fixed pages, answered with `Connection: close`. It is a
/// stand-in for the Internet (real addresses, not `file://` pages, as a site would be), so it needs no network and no Python.
final class LocalPageServer: @unchecked Sendable {
    struct Page: Sendable {
        var body: String
        var contentType = "text/html; charset=utf-8"
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.orb.tests.local-page-server")
    private let pages: [String: Page]
    private(set) var port: UInt16 = 0

    /// Starts on a free port and returns when it is ready.
    init(pages: [String: Page]) async throws {
        self.pages = pages
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [pages] connection in
            connection.start(queue: DispatchQueue.global())
            Self.serve(connection, pages: pages)
        }
        port = try await withCheckedThrowingContinuation { continuation in
            let resumed = LockedBox(false)
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if !resumed.value { resumed.value = true; continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if !resumed.value { resumed.value = true; continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    deinit { listener.cancel() }

    func stop() { listener.cancel() }

    func url(_ path: String = "/") -> String { "http://127.0.0.1:\(port)\(path)" }

    private static func serve(_ connection: NWConnection, pages: [String: Page]) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let line = request.split(separator: "\r\n").first.map(String.init) ?? ""
            let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let clean = path.split(separator: "?").first.map(String.init) ?? path
            let page = pages[clean]
            let body = Data((page?.body ?? "não encontrado").utf8)
            let head = "HTTP/1.1 \(page == nil ? "404 Not Found" : "200 OK")\r\nContent-Type: \(page?.contentType ?? "text/plain; charset=utf-8")\r\n"
                + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    // MARK: The pages

    /// The pages the real-browser tests drive: a form with a text field, two buttons, a select and a link to a second page.
    static let testSite: [String: Page] = [
        "/index.html": Page(body: """
            <!doctype html>
            <html lang="pt-BR"><head><meta charset="utf-8"><title>Página de teste do Orb</title></head>
            <body>
            <h1>Olá, navegador</h1>
            <p id="msg">Nada aconteceu ainda.</p>
            <a href="segunda.html">Ir para a segunda página</a>
            <form onsubmit="event.preventDefault(); document.getElementById('msg').textContent = 'Enviado: ' + document.getElementById('nome').value;">
              <label for="nome">Nome</label>
              <input id="nome" name="nome" type="text" placeholder="Seu nome">
              <button type="submit">Enviar</button>
            </form>
            <button id="botao" onclick="document.getElementById('msg').textContent = 'Botão clicado';">Clique aqui</button>
            <select id="cor" aria-label="Cor"><option value="r">Vermelho</option><option value="a">Azul</option></select>
            </body></html>
            """),
        "/segunda.html": Page(body: """
            <!doctype html>
            <html lang="pt-BR"><head><meta charset="utf-8"><title>Segunda página</title></head>
            <body><h1>Segunda página</h1><p>Você chegou.</p><a href="index.html">Voltar ao início</a></body></html>
            """),
    ]
}
