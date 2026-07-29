# audio-video-editor

Aplicativo desktop (Flutter/macOS) no estilo de um editor de vídeo para
manipular as faixas de arquivos `.mp4` e `.mkv`. Interface Windows 11
(Fluent Design, via [fluent_ui](https://pub.dev/packages/fluent_ui)),
pensada exclusivamente para uso horizontal em desktop (janela mínima
1100×680).

## Funcionalidades

- **Temas**: menu nativo **Temas** na barra de menus do macOS com 10 temas
  inspirados em sistemas clássicos — Windows 98, XP, Vista, 7 (Aero), 8, 10,
  11, Mac OS Clássico, macOS Moderno e Ubuntu (cores, gradientes, cantos,
  estilo dos botões e família de ícones: Fluent nos Windows, Cupertino nos
  Mac, Material no Ubuntu; não são réplicas pixel-perfect). Temas "de vidro"
  (Vista, 7 Aero, 10, macOS Moderno) ativam transparência real da janela
  (blur via NSVisualEffectView). A escolha fica salva em
  `~/.audio_video_editor/theme.txt`.
- **Barra de menus nativa**: Arquivo (Abrir ⌘O, Salvar ⌘S, adicionar
  áudio/legenda), Temas e Ajuda.

- **Layout de editor de vídeo**: lista de faixas à esquerda, preview do vídeo
  no centro, propriedades à direita e linha do tempo na parte inferior, com
  playhead, régua, zoom e campo "ir para" (aceita `90`, `1:30`, `1:02:03.5`).
- **Preview com reprodução** (via [media_kit](https://pub.dev/packages/media_kit)/libmpv,
  toca MKV e MP4): play/pause (espaço), −5s/+5s, playhead sincronizado com a
  linha do tempo. Dá para escolher qual faixa de áudio ouvir (inclusive
  arquivos externos adicionados); o deslocamento do trecho monitorado é
  aplicado em tempo real via `audio-delay` do mpv — bom para acertar a
  posição das falas. (Aproximação: cortes/mesclas multi-trecho só são
  ouvidos exatamente no arquivo salvo.)
- **Dividir e excluir trechos de áudio**: posicione o playhead, selecione a
  faixa/trecho e use *Dividir* (tecla **S**) / *Excluir trecho*
  (**Del/Backspace** — sem trecho selecionado, remove a faixa inteira).
  Cada faixa de áudio é uma sequência de trechos arrastáveis na linha do
  tempo (com snap no playhead e nas bordas vizinhas). **Espaço** dá
  play/pause.
- **Automesclagem ao salvar**: faixas de áudio que foram cortadas
  (divididas/aparadas) são mescladas automaticamente em uma única faixa de
  saída, na posição em que estão na linha do tempo — ex.: os 3 primeiros
  minutos do áudio 1 seguidos do restante do áudio 2. Faixas intactas ou
  apenas deslocadas continuam como faixas separadas. As lanes que serão
  mescladas mostram um ícone no cabeçalho, e o diálogo de salvar lista a
  mesclagem antes de executar.
- Adicionar faixas de áudio externas (`mp3`, `aac`, `m4a`, `ac3`, `eac3`,
  `flac`, `wav`, `opus`, `ogg`, `dts`, `mka`) e legendas (`srt`, `ass`,
  `ssa`, `vtt`, `sub`).
- Remover/restaurar faixas, renomear título de qualquer faixa, deslocar
  legendas no tempo.
- Exportar uma faixa de áudio original sem perda (extensão escolhida pelo
  codec: AAC → `.m4a`, MP3 → `.mp3` etc.).
- Salvar em `.mkv` ou `.mp4` com barra de progresso.

## Como o arquivo é gerado

Tudo via `ffprobe`/`ffmpeg` como processos externos
([lib/services/ffmpeg_service.dart](lib/services/ffmpeg_service.dart)):

- Faixas **intactas** são copiadas sem re-encode (`-c copy`; atraso puro vira
  `-itsoffset`, corte só do início vira `-ss`).
- Faixas **editadas** (divididas, cortadas ou mescladas) passam por
  `-filter_complex` (`atrim` → `asetpts` → `aresample` → `adelay` → `amix`)
  e são re-encodadas em AAC 256k; as demais continuam em cópia direta.
- Legendas `srt` viram `mov_text` em MP4; áudio incompatível com MP4 vira AAC.

## Requisitos

- macOS
- [Flutter](https://flutter.dev)
- FFmpeg: `brew install ffmpeg` (procurado em `/opt/homebrew/bin`,
  `/usr/local/bin`, `/usr/bin`)

## Rodando

```sh
flutter run -d macos
```

Ou gere o app (aceita um vídeo como argumento):

```sh
flutter build macos --release
open build/macos/Build/Products/Release/audio_video_editor.app --args /caminho/video.mkv
```

## Testes

```sh
flutter test          # unit + widget (inclui montagem dos args do ffmpeg)
dart run tool/e2e.dart  # end-to-end com ffmpeg real (gera mídia, salva, valida conteúdo)
```

O App Sandbox do macOS está desativado nos entitlements para permitir
executar o FFmpeg e ler arquivos arbitrários.

As artes-fonte do ícone ficam em [assets/icon/](assets/icon/); os tamanhos do
ícone macOS foram gerados a partir de `icon.png` (via `sips`) em
`macos/Runner/Assets.xcassets/AppIcon.appiconset/`.
