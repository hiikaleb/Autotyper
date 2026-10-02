"""
Capturador automatico de cookies (login assistido) via Playwright

Substitui a extensao "Get cookies.txt LOCALLY": abre um navegador de
verdade, voce loga normalmente (ou ja usa seu perfil onde ja esta
logado), e o script exporta os cookies certinho pro formato Netscape
que o yt-dlp entende - tudo automatico, sem instalar nada no navegador.

Uso:
    python capturar_cookies.py [URL] [caminho_do_cookies.txt]

Sem argumentos, abre o Epidemic Sound e salva em cookies.txt do lado
deste script.
"""

import os
import sys
import time
from pathlib import Path
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

SITE_PADRAO = "https://www.epidemicsound.com/"


def pasta_perfil_local(motor, canal):
    nome = f"PlaywrightProfile_{motor}" + (f"_{canal}" if canal else "")
    base = Path(__file__).parent / "_internal" / nome
    base.mkdir(parents=True, exist_ok=True)
    return base


def pasta_perfil_real(canal):
    local_appdata = os.environ.get("LOCALAPPDATA", "")
    if canal == "chrome":
        return Path(local_appdata) / "Google" / "Chrome" / "User Data"
    if canal == "msedge":
        return Path(local_appdata) / "Microsoft" / "Edge" / "User Data"
    return None


def dominio_pertence(dominio_cookie: str, dominio_alvo: str) -> bool:
    d = dominio_cookie.lstrip(".")
    return d == dominio_alvo or d.endswith("." + dominio_alvo)


def escrever_netscape(cookies, destino: Path, dominio_alvo: str) -> int:
    linhas = [
        "# Netscape HTTP Cookie File",
        "# Gerado automaticamente por capturar_cookies.py - nao editar na mao",
        "",
    ]
    # Cookie de sessao (sem data de expiracao) recebe uma validade de 2 anos
    # aqui no arquivo, so pra ele nao "expirar" no meio de uma sessao de uso -
    # a sessao real continua dependendo do proprio login no site.
    expira_padrao = int(time.time()) + (2 * 365 * 24 * 3600)

    total = 0
    for c in cookies:
        dominio = c.get("domain", "")
        if not dominio_pertence(dominio, dominio_alvo):
            continue

        flag = "TRUE" if dominio.startswith(".") else "FALSE"
        caminho = c.get("path") or "/"
        seguro = "TRUE" if c.get("secure") else "FALSE"
        expira = c.get("expires", -1)
        if not expira or expira < 0:
            expira = expira_padrao
        expira = int(expira)
        nome = c.get("name", "")
        valor = c.get("value", "")

        linhas.append(f"{dominio}\t{flag}\t{caminho}\t{seguro}\t{expira}\t{nome}\t{valor}")
        total += 1

    destino.write_text("\n".join(linhas) + "\n", encoding="utf-8")
    return total


def extrair_dominio(url: str) -> str:
    if "://" not in url:
        url = f"https://{url}"
    dominio = urlparse(url).netloc.split(":")[0]
    if dominio.startswith("www."):
        dominio = dominio[4:]
    return dominio


def resolver_escolha(codigo):
    codigo = (codigo or "").strip().lower()
    if codigo == "msedge":
        return "chromium", "msedge", True
    if codigo == "chromium":
        return "chromium", None, False
    if codigo == "firefox":
        return "firefox", None, False
    # "chrome" ou qualquer coisa desconhecida cai no padrao mais comum
    return "chromium", "chrome", True


def main():
    url = sys.argv[1] if len(sys.argv) > 1 else SITE_PADRAO
    destino = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(__file__).parent / "cookies.txt"
    navegador_forcado = sys.argv[3] if len(sys.argv) > 3 else None
    dominio_alvo = extrair_dominio(url)

    print("=" * 60)
    print("  CAPTURADOR DE COOKIES (login assistido)")
    print("=" * 60)
    print(f"Site: {url}")
    print(f"Vai salvar em: {destino}")
    print()

    if navegador_forcado:
        # Chamado automaticamente pelo motor - sem menu, direto ao ponto.
        motor, canal, perfil_real = resolver_escolha(navegador_forcado)
    else:
        print("1 - Chrome (perfil real, ja logado)")
        print("2 - Edge (perfil real, ja logado)")
        print("3 - Chromium avulso (janela nova, precisa logar agora)")
        print("4 - Firefox avulso (janela nova, precisa logar agora)")
        escolha = input("Escolha: ").strip()
        codigo = {"2": "msedge", "3": "chromium", "4": "firefox"}.get(escolha, "chrome")
        motor, canal, perfil_real = resolver_escolha(codigo)

    if perfil_real:
        perfil = pasta_perfil_real(canal)
        print(f"\nUsando o perfil real do navegador em: {perfil}")
        print("Feche TODAS as janelas desse navegador antes de continuar (senao da erro de 'perfil em uso').")
        input("Pressione ENTER quando tiver certeza que fechou... ")
    else:
        perfil = pasta_perfil_local(motor, canal)
        print("\nAbrindo uma janela nova (perfil separado, sem seus dados de sempre).")

    with sync_playwright() as p:
        navegador = getattr(p, motor)
        kwargs = {"headless": False}
        if canal:
            kwargs["channel"] = canal

        try:
            contexto = navegador.launch_persistent_context(str(perfil), **kwargs)
        except Exception as e:
            print(f"\nErro ao abrir o navegador: {e}")
            print("Se a mensagem falar de 'profile in use' / 'in use', feche TODAS as janelas")
            print("desse navegador (confere o Gerenciador de Tarefas tambem) e tenta de novo.")
            sys.exit(1)

        try:
            pagina = contexto.pages[0] if contexto.pages else contexto.new_page()
            try:
                pagina.goto(url, wait_until="domcontentloaded", timeout=30000)
            except Exception as e:
                print(f"\n[aviso] nao consegui navegar automaticamente ate a pagina ({e}).")
                print("Navegue voce mesmo ate o site na janela que abriu.")

            print()
            if not perfil_real:
                print("Faca login normalmente nessa janela que abriu.")
            print("Quando estiver logado (ou se ja estava, no caso do perfil real),")
            input("volte aqui e pressione ENTER pra eu capturar os cookies... ")

            cookies = contexto.cookies()
            total = escrever_netscape(cookies, destino, dominio_alvo)

            if total > 0:
                print(f"\nPronto! {total} cookies de '{dominio_alvo}' salvos em: {destino}")
            else:
                print(f"\nNao encontrei nenhum cookie de '{dominio_alvo}'.")
                print("Confirma que voce realmente logou e que a URL esta certa.")
        finally:
            try:
                contexto.close()
            except Exception:
                pass


if __name__ == "__main__":
    main()
