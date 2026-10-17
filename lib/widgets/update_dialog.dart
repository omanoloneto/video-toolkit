import 'package:fluent_ui/fluent_ui.dart';

import '../services/updater.dart';

/// Baixa e instala [release] mostrando o progresso. Devolve true quando a
/// versão nova já foi aberta e este app deve fechar. Com [confirmRestart],
/// pergunta antes de reabrir (tem arquivo aberto, talvez com edição).
Future<bool> showUpdateDialog(
  BuildContext context, {
  required Updater updater,
  required AppRelease release,
  required String current,
  bool confirmRestart = false,
  List<String> relaunchArgs = const [],
}) async {
  final restarted = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _UpdateDialog(
      updater: updater,
      release: release,
      current: current,
      confirmRestart: confirmRestart,
      relaunchArgs: relaunchArgs,
    ),
  );
  return restarted ?? false;
}

enum _Stage { downloading, ready, installing, failed }

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({
    required this.updater,
    required this.release,
    required this.current,
    required this.confirmRestart,
    required this.relaunchArgs,
  });

  final Updater updater;
  final AppRelease release;
  final String current;
  final bool confirmRestart;
  final List<String> relaunchArgs;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  _Stage _stage = _Stage.downloading;
  double? _progress;
  String _error = '';
  bool _cancelled = false;
  Future<void> Function()? _install;

  @override
  void initState() {
    super.initState();
    _download();
  }

  Future<void> _download() async {
    try {
      final file = await widget.updater.download(
        widget.release,
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
        cancelled: () => _cancelled,
      );
      if (_cancelled || !mounted) return;
      _install = () =>
          widget.updater.install(file, relaunchArgs: widget.relaunchArgs);
      if (widget.confirmRestart) {
        setState(() => _stage = _Stage.ready);
      } else {
        await _restart();
      }
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _restart() async {
    final install = _install;
    if (install == null) return;
    setState(() => _stage = _Stage.installing);
    try {
      await install();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      _fail(e);
    }
  }

  void _fail(Object error) {
    if (_cancelled || !mounted) return;
    setState(() {
      _stage = _Stage.failed;
      _error = error is UpdateException
          ? error.message
          : 'Sem conexão com o GitHub ou o download parou no meio.';
    });
  }

  void _close() {
    _cancelled = true;
    Navigator.pop(context, false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final secondary = TextStyle(
        color: theme.resources.textFillColorSecondary, fontSize: 12);
    return ContentDialog(
      title: const Text('Atualizando o Video Toolkit'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('A versão ${widget.release.version} saiu — você está na '
              '${widget.current}.'),
          const SizedBox(height: 14),
          switch (_stage) {
            _Stage.downloading => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ProgressBar(value: _progress == null ? null : _progress! * 100),
                  const SizedBox(height: 8),
                  Text(
                      _progress == null
                          ? 'Baixando…'
                          : 'Baixando… ${(_progress! * 100).round()}%',
                      style: secondary),
                ],
              ),
            _Stage.ready => const Text('Pronta pra instalar. O app fecha e '
                'reabre na versão nova; o que não foi salvo se perde.'),
            _Stage.installing => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const ProgressBar(),
                  const SizedBox(height: 8),
                  Text('Instalando… o app reabre sozinho.', style: secondary),
                ],
              ),
            _Stage.failed => InfoBar(
                title: const Text('Não deu pra atualizar sozinho'),
                content: Text('$_error Baixe a versão nova na página do '
                    'app: ${kDownloadPage.host}${kDownloadPage.path}'),
                severity: InfoBarSeverity.warning,
                isLong: true,
              ),
          },
        ],
      ),
      actions: switch (_stage) {
        _Stage.downloading => [
            Button(onPressed: _close, child: const Text('Agora não')),
          ],
        _Stage.ready => [
            Button(onPressed: _close, child: const Text('Depois')),
            FilledButton(
                onPressed: _restart, child: const Text('Reiniciar agora')),
          ],
        _Stage.installing => const [],
        _Stage.failed => [
            Button(onPressed: _close, child: const Text('Fechar')),
            FilledButton(
              onPressed: () {
                openInBrowser(kDownloadPage);
                _close();
              },
              child: const Text('Abrir a página'),
            ),
          ],
      },
    );
  }
}
