# Como estender o AutoTyper (guia para você + Claude)

Este app tem só 3 arquivos que importam pra adicionar uma função nova. Sempre que
for pedir uma extensão pro Claude, jogue o projeto inteiro (ou pelo menos esses 3
arquivos) e cole o bloco "Prompt pronto" lá embaixo, editado com o que você quer.

## Arquitetura em 1 minuto

```
main.py       -> back-end Python. Tudo que precisa do sistema operacional
                 (arquivos, processos como ffmpeg/yt-dlp, teclado, tela) vive
                 aqui. Funções soltas fazem o trabalho; a classe `Api` no fim
                 do arquivo é a única ponte visível pro JavaScript — cada
                 método dela vira `window.pywebview.api.nome_do_metodo(...)`
                 no front-end.
index.html    -> estrutura visual. Cada aba do topo é uma <section class="view">
                 com id="view-NOME". A aba "Extensões" é um hub: cada
                 <button class="ext-card"> abre uma view própria (view-ext-*).
script.js     -> o que acontece quando você clica em algo. Chama
                 window.pywebview.api.*, recebe {ok, ...} de volta, atualiza o DOM.
style.css     -> visual. Usa variáveis CSS (--accent, --bg-panel, etc.) no topo
                 do arquivo — mude ali pra re-tematizar o app inteiro.
engine/       -> só binários e scripts auxiliares (yt-dlp.exe, ffmpeg.exe,
                 farejador_universal.py). NÃO é uma pasta pra você jogar seus
                 próprios arquivos de projeto — isso é o que fica dentro de
                 "Projetos/<nome do projeto>/", que você configura em
                 Configurações > Projetos e arquivos > "Pasta raiz dos projetos".
```

## O padrão pra adicionar uma extensão nova (função nova na aba Extensões)

Toda extensão existente (Digitação, Screenshots, Memória, Motor de download)
segue o mesmo esqueleto de 4 peças. Uma extensão nova = repetir esse esqueleto:

1. **Função Python** em `main.py` que faz o trabalho de verdade, retornando
   sempre `{"ok": True/False, ...}`.
2. **Método na classe `Api`** que só chama essa função (é o que expõe pro JS).
3. **Card no hub** dentro de `<section id="view-extensions">` em `index.html`
   (`<button class="ext-card" onclick="switchView('ext-NOME')">`).
4. **View própria** (`<section class="view hidden" id="view-ext-NOME">`) com o
   botão "Voltar para Extensões", e o **JS em `script.js`** que chama
   `window.pywebview.api.NOME(...)` e atualiza a tela com o resultado.

## Prompt pronto pra pedir uma extensão nova ao Claude

Copie, edite os `[colchetes]` e cole junto com o projeto:

```
Quero adicionar uma extensão nova no AutoTyper, seguindo o padrão descrito
em EXTENDING.md (função em main.py + método em Api + card no hub de
Extensões + view própria + JS).

O que a extensão faz: [descreva em 1-2 frases]
Entrada do usuário (se houver): [ex: um texto, um arquivo, nenhuma]
Saída esperada: [ex: um arquivo salvo, uma mensagem, dados na tela]
Nome pro botão/card: [ex: "Conversor de legendas"]
```

Isso já dá pro Claude contexto suficiente pra implementar sem ficar
adivinhando onde encaixar as coisas.
