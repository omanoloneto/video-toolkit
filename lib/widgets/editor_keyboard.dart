import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// Atalhos do editor (espaço, S, Del). Clique fora de campo de texto, Enter
/// ou campo que some devolvem o foco pra cá: sem isso os atalhos param de
/// funcionar depois de digitar em qualquer campo.
class EditorKeyboard extends StatefulWidget {
  const EditorKeyboard({super.key, required this.onKey, required this.child});

  /// Só teclas sem Ctrl/⌘/Alt: Ctrl+S no Windows não pode dividir o trecho.
  final KeyEventResult Function(KeyEvent event) onKey;
  final Widget child;

  @override
  State<EditorKeyboard> createState() => _EditorKeyboardState();
}

class _EditorKeyboardState extends State<EditorKeyboard> {
  final _node = FocusNode(debugLabel: 'editor');

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_reclaimFromScope);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_reclaimFromScope);
    _node.dispose();
    super.dispose();
  }

  // campo de texto que perde o foco devolve pro escopo da tela, fora daqui
  void _reclaimFromScope() {
    final primary = FocusManager.instance.primaryFocus;
    if (primary != null &&
        identical(primary, _node.enclosingScope) &&
        !_node.hasPrimaryFocus) {
      _node.requestFocus();
    }
  }

  void _reclaimOnPointer(PointerDownEvent event) {
    if (_node.hasPrimaryFocus) return;
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, event.position, event.viewId);
    if (result.path.any((entry) => entry.target is RenderEditable)) return;
    _node.requestFocus();
  }

  KeyEventResult _handle(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final focused = FocusManager.instance.primaryFocus?.context;
    final typing =
        focused?.widget is EditableText ||
        focused?.findAncestorWidgetOfExactType<EditableText>() != null;
    if (typing) return KeyEventResult.ignored;
    return widget.onKey(event);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _reclaimOnPointer,
      child: Focus(
        focusNode: _node,
        autofocus: true,
        onKeyEvent: _handle,
        child: widget.child,
      ),
    );
  }
}
