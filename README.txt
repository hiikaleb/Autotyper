# AutoTyper - versão com bandeja do sistema

## Novidades desta versão

- O app agora roda com ícone na bandeja do sistema (system tray), igual
  ao ReduceMemory: ao fechar a janela, ele minimiza para a bandeja em
  vez de encerrar, e continua ouvindo os atalhos em segundo plano.
  Clique com o botão direito no ícone da bandeja para: Mostrar, Iniciar/
  Parar, Screenshot, Screenshot de área ou Sair.
- Screenshot agora tem dois modos:
    F8            -> tira print da tela inteira (como antes)
    SHIFT + F8    -> abre uma seleção de área: arraste o mouse na tela
                     para escolher uma região específica e só ela é
                     salva. ESC cancela a seleção.
  Os dois atalhos podem ser trocados em Configurações, assim como
  minimizar para bandeja e iniciar oculto.

## Gerar o EXE

1. Abra esta pasta no VS Code.
2. Abra o terminal.
3. Execute:

    build_improved.bat

O script instala as dependências (incluindo o pystray, usado pela
bandeja) e gera:

    dist\AutoTyper\AutoTyper.exe

## Uso

Dê dois cliques em AutoTyper.exe.

A pasta `dist\AutoTyper` deve ser mantida inteira, pois contém a
interface HTML/CSS/JS e as DLLs do Python empacotadas.

Padrões:
- Ctrl + Alt + Print Screen: iniciar/parar digitação
- F8: screenshot da tela inteira
- Shift + F8: screenshot de uma área selecionada

## Sobre o erro "404 Not Found" / "index.html File does not exist"

A partir do PyInstaller 6, o modo `--onedir` passou a colocar TODOS os
arquivos internos (DLLs, e também `index.html`, `style.css`, `script.js`,
`config.json`) dentro de uma subpasta `_internal`, e não mais direto ao
lado do `AutoTyper.exe`. Se isso não for levado em conta no código, o
app procura o `index.html` no lugar errado e mostra "404 Not Found".

Já corrigido nesta versão: o `main.py` agora distingue dois locais:
- `resource_dir()` -> onde estão os arquivos empacotados (HTML/CSS/JS/
  ícone), que é `sys._MEIPASS` (a pasta `_internal`) quando rodando
  como .exe.
- `data_dir()` -> onde ficam os arquivos graváveis (`config.json` e a
  pasta de screenshots), que continua sendo ao lado do `.exe`, para não
  precisar de permissão de escrita dentro de `_internal`.

## Sobre os avisos de antivírus / erro de DLL não encontrada

Esse tipo de erro:

    Failed to load Python DLL '...\_internal\python312.dll'
    LoadLibrary: The specified module could not be found.

quase sempre acontece porque o antivírus (Windows Defender ou outro)
apagou ou colocou em quarentena algum arquivo de dentro da pasta
`_internal` DEPOIS que o PyInstaller gerou o build — normalmente o
próprio python312.dll ou alguma DLL do pyautogui/keyboard.

Por que isso acontece: este programa usa hooks de teclado (biblioteca
`keyboard`) e injeta digitação na tela (`pyautogui`). Tecnicamente é
o mesmo tipo de comportamento de um keylogger/RAT, então engines
heurísticos de antivírus podem marcar o executável como suspeito
mesmo sem haver nada malicioso no código. Compactar o .exe com UPX
(como o build antigo fazia) piora ainda mais isso, porque some com a
"assinatura" do binário e é um padrão clássico usado por malware para
se esconder — por isso o UPX foi desativado neste .spec.

Para reduzir o problema:
1. Antes de rodar o build, adicione a pasta do projeto E a pasta
   dist\ nas exclusões do Windows Defender (Configurações > Privacidade
   e segurança > Segurança do Windows > Proteção contra vírus e ameaças
   > Gerenciar configurações > Adicionar ou remover exclusões > Pasta).
2. Rode o build de novo do zero (build_improved.bat já limpa build\ e
   dist\ antes de gerar).
3. Se for distribuir o programa para terceiros (não só para você),
   o ideal é assinar o executável com um certificado de code signing;
   sem isso, é normal que o SmartScreen do Windows mostre um aviso na
   primeira execução, mesmo com o antivírus liberando o arquivo.
4. Se algum antivírus específico continuar acusando falso positivo,
   dá pra reportar o arquivo direto para o fabricante (ex.: portal de
   "submissão de falso positivo" da Microsoft/Avast/Kaspersky etc.)
   pedindo a reclassificação.
