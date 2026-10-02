"""
Farejador de audio universal (Chrome, Firefox, Edge ou outro Chromium) via Playwright

Pre-requisitos (uma vez so):
    pip install playwright
    python -m playwright install chromium firefox

Como usar:
    python farejador_universal.py
    -> escolhe o navegador (abre uma janela dedicada, perfil separado)
    -> navega no site, faz login se precisar, da play nas faixas
    -> os audios detectados aparecem numerados aqui no terminal, com tamanho aproximado
    -> digita o numero pra salvar

Comandos disponiveis no prompt:
    <numero>  -> salva o audio daquele numero
    listar    -> mostra de novo todos os audios ja detectados
    sair      -> fecha o navegador sozinho e encerra o programa

Vantagem sobre pegar o link manualmente: o arquivo salvo e o corpo real da resposta que
o navegador ja recebeu, entao nao tem risco de token de CDN expirar no meio do caminho.
"""

import re
import os
import sys
import threading
from pathlib import Path

from playwright.sync_api import sync_playwright

# Evita crash silencioso ao imprimir titulos/URLs com acentos ou emoji em
# consoles do Windows que usam uma codepage antiga (cp1252 etc).
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

if len(sys.argv) > 1:
    PASTA_DESTINO = Path(sys.argv[1])
else:
    PASTA_DESTINO = Path(__file__).parent / "Baixar" / "Audios" / "Diretos"
PASTA_DESTINO.mkdir(parents=True, exist_ok=True)

PADROES_URL_EXTRA = (
    "epidemicsound.com",
    "sndcdn.com",
    "soundcloud.com",
    ".mp3",
    ".wav",
    ".m4a",
    ".flac",
    ".ogg",
)

MAPA_EXTENSAO = {
    "audio/mpeg": "mp3",
    "audio/mp3": "mp3",
    "audio/wav": "wav",
    "audio/x-wav": "wav",
    "audio/mp4": "m4a",
    "audio/aac": "aac",
    "audio/flac": "flac",
    "audio/ogg": "ogg",
}

encontrados = []  # cada item: {"url":..., "mime":..., "bytes":...}
lock = threading.Lock()


def parece_audio(url, mime):
    if mime and mime.startswith("audio/"):
        return True
    url_lower = url.lower()
    return any(p in url_lower for p in PADROES_URL_EXTRA)


def extensao_por_mime_ou_url(mime, url):
    if mime in MAPA_EXTENSAO:
        return MAPA_EXTENSAO[mime]
    m = re.search(r"\.(mp3|wav|m4a|aac|flac|ogg)(\?|$)", url.lower())
    if m:
        return m.group(1)
    return "mp3"


def listar_encontrados():
    with lock:
        copia = list(encontrados)
    if not copia:
        print("\nNenhum audio detectado ainda. Continue navegando e dando play.")
        return
    print("\n----------- AUDIOS DETECTADOS -----------")
    for i, item in enumerate(copia, start=1):
        tamanho_kb = len(item["bytes"]) // 1024
        print(f"[{i}] {item['mime'] or '???'}  (~{tamanho_kb} KB)")
        print(f"     {item['url']}")
    print("------------------------------------------")


def registrar_pagina(page):
    def ao_receber_resposta(response):
        # IMPORTANTE: essa funcao roda numa thread interna do Playwright.
        # Qualquer excecao nao tratada aqui pode derrubar a escuta de novas
        # respostas sem avisar (o sintoma era "parou de detectar audio do
        # nada"). Por isso TUDO fica dentro de um try/except bem amplo.
        try:
            url = response.url
            mime = response.headers.get("content-type", "").split(";")[0].strip()

            if not parece_audio(url, mime):
                return

            with lock:
                if any(item["url"] == url for item in encontrados):
                    return

            try:
                corpo = response.body()
            except Exception:
                return  # resposta descartada, redirecionamento, ou stream ainda incompleto

            if len(corpo) < 5000:
                return  # provavelmente nao e o audio real (ex: resposta de metadata/preview curta)

            with lock:
                if any(item["url"] == url for item in encontrados):
                    return
                encontrados.append({"url": url, "mime": mime, "bytes": corpo})
                idx = len(encontrados)

            tamanho_kb = len(corpo) // 1024
            print(f"\n[{idx}] NOVO AUDIO DETECTADO -- {mime or '???'}  (~{tamanho_kb} KB)")
            print(f"     {url}")
            print("Digite o numero pra salvar | 'listar' pra rever | 'sair' pra fechar: ", end="", flush=True)
        except Exception as e:
            try:
                print(f"\n[aviso] ignorei uma resposta com problema ({e}). Continuando a escutar...")
            except Exception:
                pass

    page.on("response", ao_receber_resposta)


def pasta_perfil_real(canal):
    local_appdata = os.environ.get("LOCALAPPDATA", "")
    if canal == "chrome":
        return Path(local_appdata) / "Google" / "Chrome" / "User Data"
    if canal == "msedge":
        return Path(local_appdata) / "Microsoft" / "Edge" / "User Data"
    return None


def pasta_perfil_local(motor, canal):
    # Perfis de navegador avulso (nao real) ficam escondidos dentro de
    # _internal, pra nao poluir a pasta principal do motor.
    nome = f"PlaywrightProfile_{motor}" + (f"_{canal}" if canal else "")
    base = Path(__file__).parent / "_internal" / nome
    base.mkdir(parents=True, exist_ok=True)
    return base


def main():
    print("=" * 60)
    print("  FAREJADOR DE AUDIO UNIVERSAL")
    print("=" * 60)
    print("1 - Chrome")
    print("2 - Firefox")
    print("3 - Edge")
    print("4 - Outro (Chromium customizado: Brave, Opera, Vivaldi...)")
    escolha = input("Escolha o navegador: ").strip()

    executavel_customizado = None

    if escolha == "2":
        motor = "firefox"
        canal = None
    elif escolha == "3":
        motor = "chromium"
        canal = "msedge"
    elif escolha == "4":
        motor = "chromium"
        canal = None
        executavel_customizado = input("Caminho completo do .exe do navegador: ").strip().strip('"')
        if not Path(executavel_customizado).exists():
            print("Esse caminho nao existe. Confere e tenta de novo.")
            return
    else:
        motor = "chromium"
        canal = "chrome"  # usa o Chrome instalado na maquina

    perfil = None
    if canal in ("chrome", "msedge"):
        resp = input(
            "Usar seu perfil REAL desse navegador, com seus logins ja salvos? "
            "Precisa fechar TODAS as janelas dele antes (s/N): "
        ).strip().lower()
        if resp == "s":
            perfil = pasta_perfil_real(canal)
            print(f"\nUsando perfil real em: {perfil}")
            print("Confirma que fechou TODAS as janelas desse navegador (senao vai dar erro de 'perfil em uso').")
            input("Pressione ENTER quando tiver certeza que fechou... ")

    if perfil is None:
        perfil = pasta_perfil_local(motor, canal)
        print("\nAbrindo navegador... (perfil separado - pode pedir login de novo na primeira vez)")

    with sync_playwright() as p:
        navegador = getattr(p, motor)
        kwargs = {"headless": False}
        if canal:
            kwargs["channel"] = canal
        if executavel_customizado:
            kwargs["executable_path"] = executavel_customizado

        try:
            contexto = navegador.launch_persistent_context(str(perfil), **kwargs)
        except Exception as e:
            print(f"\nErro ao abrir o navegador: {e}")
            print("Se a mensagem falar de 'profile in use' / 'in use', feche TODAS as")
            print("janelas do navegador (confere o Gerenciador de Tarefas tambem) e tenta de novo.")
            return

        # A partir daqui, SEMPRE fechamos o navegador no final (finally),
        # nao importa se o programa terminou normal, deu erro ou foi Ctrl+C.
        try:
            for pagina in contexto.pages:
                registrar_pagina(pagina)
            contexto.on("page", registrar_pagina)

            if not contexto.pages:
                contexto.new_page()

            print("\nNavegue e de play nos audios/SFX. Os links detectados vao aparecer aqui.")
            print("Comandos: numero = salvar | 'listar' = rever a lista | 'sair' = fechar o navegador\n")

            while True:
                try:
                    entrada = input().strip()
                except (KeyboardInterrupt, EOFError):
                    print("\nEncerrando e fechando o navegador...")
                    break

                if not entrada:
                    continue

                comando = entrada.lower()

                if comando in ("sair", "exit", "quit", "0"):
                    print("Fechando o navegador...")
                    break

                if comando in ("listar", "lista", "ls"):
                    listar_encontrados()
                    continue

                with lock:
                    try:
                        idx = int(entrada) - 1
                        item = encontrados[idx]
                    except (ValueError, IndexError):
                        print("Numero invalido. Digite 'listar' pra ver os disponiveis, ou 'sair' pra fechar.")
                        continue

                nome = input("Nome do arquivo (ENTER usa 'audio'): ").strip() or "audio"
                nome_limpo = re.sub(r'[\\/:\*\?"<>\|]', "_", nome) or "audio"
                ext = extensao_por_mime_ou_url(item["mime"], item["url"])
                destino = PASTA_DESTINO / f"{nome_limpo}.{ext}"
                destino.write_bytes(item["bytes"])
                print(f"Salvo em: {destino}\n")
        finally:
            try:
                contexto.close()
                print("Navegador fechado. Ate a proxima!")
            except Exception:
                print("Aviso: nao consegui confirmar o fechamento do navegador (confira o Gerenciador de Tarefas).")


if __name__ == "__main__":
    main()
