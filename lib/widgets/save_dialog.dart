import 'package:fluent_ui/fluent_ui.dart';

import '../services/ffmpeg_service.dart';

/// Confirma o salvar: como a imagem sai e o que vai mudar. Devolve o
/// formato escolhido, ou null quando cancelou.
Future<VideoFormat?> showSaveDialog(
  BuildContext context, {
  required bool videoEdited,
  required List<String> Function(VideoFormat format) warningsFor,
}) =>
    showDialog<VideoFormat>(
      context: context,
      builder: (context) => _SaveDialog(
        videoEdited: videoEdited,
        warningsFor: warningsFor,
      ),
    );

class _SaveDialog extends StatefulWidget {
  const _SaveDialog({required this.videoEdited, required this.warningsFor});

  final bool videoEdited;
  final List<String> Function(VideoFormat format) warningsFor;

  @override
  State<_SaveDialog> createState() => _SaveDialogState();
}

class _SaveDialogState extends State<_SaveDialog> {
  // vídeo cortado só sai recodificado: o corte exato não cai em keyframe
  late VideoFormat _format =
      widget.videoEdited ? VideoFormat.av1 : VideoFormat.keep;

  static const _labels = {
    VideoFormat.keep: 'Manter o original (sem recodificar)',
    VideoFormat.av1: 'AV1 — menor, mesma qualidade',
    VideoFormat.hevc: 'H.265 — toca em mais aparelhos',
  };

  static const _descriptions = {
    VideoFormat.keep: 'Copia a imagem como está: salva em segundos e fica do '
        'mesmo tamanho.',
    VideoFormat.av1: 'Cerca de metade do tamanho com a mesma qualidade. Toca '
        'no VLC, no Chrome e em TVs recentes; em aparelhos da Apple, só nos '
        'mais novos.',
    VideoFormat.hevc: 'Quase o mesmo tamanho do AV1 e toca em mais aparelhos, '
        'inclusive Apple, mas salvar demora bem mais.',
  };

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final warnings = widget.warningsFor(_format);
    return ContentDialog(
      title: const Text('Salvar vídeo'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InfoLabel(
            label: 'Formato do vídeo',
            child: ComboBox<VideoFormat>(
              isExpanded: true,
              value: _format,
              items: [
                for (final format in VideoFormat.values)
                  if (!(widget.videoEdited && format == VideoFormat.keep))
                    ComboBoxItem(
                      value: format,
                      child: Text(_labels[format]!),
                    ),
              ],
              onChanged: (format) {
                if (format != null) setState(() => _format = format);
              },
            ),
          ),
          const SizedBox(height: 8),
          Text(_descriptions[_format]!,
              style: TextStyle(
                  color: theme.resources.textFillColorSecondary,
                  fontSize: 12)),
          if (warnings.isNotEmpty) ...[
            const SizedBox(height: 14),
            for (final warning in warnings)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('• $warning'),
              ),
          ],
        ],
      ),
      actions: [
        Button(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _format),
          child: const Text('Salvar'),
        ),
      ],
    );
  }
}
