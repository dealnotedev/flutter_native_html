import 'dart:io' show Platform;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../flutter_native_html.dart';
import 'email_input.dart';
import 'eml_message.dart';
import 'sample_emails.dart';

/// Showcase screen for [HtmlEmailView]: pick a sample email, toggle remote
/// image loading, and see link/image taps surfaced as snackbars.
class EmailDemoWidget extends StatefulWidget {
  const EmailDemoWidget({super.key});

  @override
  State<EmailDemoWidget> createState() => _EmailDemoWidgetState();
}

class _EmailDemoWidgetState extends State<EmailDemoWidget> {
  int _loadRevision = 0;
  int _selected = 0;
  bool _allowRemoteImages = false;
  bool _fitToWidth = true;
  bool _isDraggingEml = false;

  /// HTML loaded from disk; when set it takes precedence over the samples.
  String? _loadedHtml;
  String? _loadedFileName;

  /// Inline images (cid) extracted from a loaded `.eml`, fed to the resolver.
  Map<String, Uint8List> _inlineImages = const {};

  /// Native bridge for `.eml` files opened from other apps (see MainActivity).
  static const _emlChannel = MethodChannel('tech.plink.flutter_html/eml');

  SampleEmail get _sample => kSampleEmails[_selected];

  String get _currentHtml => _loadedHtml ?? _sample.html;

  bool get _canDropFiles => !kIsWeb && Platform.isWindows;

  @override
  void initState() {
    super.initState();
    // Android can launch us with an .eml ("open with" / share). Listen for
    // files opened while running, then check for one that launched us cold.
    if (!kIsWeb && Platform.isAndroid) {
      _emlChannel.setMethodCallHandler(_onChannelCall);
      _loadInitialEml();
    }
  }

  @override
  void dispose() {
    if (!kIsWeb && Platform.isAndroid) {
      _emlChannel.setMethodCallHandler(null);
    }
    super.dispose();
  }

  Future<void> _loadInitialEml() async {
    final revision = _loadRevision;
    try {
      final payload = await _emlChannel.invokeMapMethod<String, dynamic>(
        'getInitialEml',
      );
      if (!mounted || revision != _loadRevision) return;
      await _ingestPayload(payload);
    } catch (_) {
      // No launch file, or the platform has no channel — ignore.
    }
  }

  Future<dynamic> _onChannelCall(MethodCall call) async {
    if (call.method == 'onEml' && call.arguments is Map) {
      await _ingestPayload(Map<String, dynamic>.from(call.arguments as Map));
    }
  }

  /// Handles a `{name, bytes}` payload from the native side.
  Future<void> _ingestPayload(Map<String, dynamic>? payload) async {
    if (!mounted || payload == null) return;
    final error = payload['error'];
    if (error is String) {
      _toast(error);
      return;
    }
    final bytes = payload['bytes'];
    if (bytes is! Uint8List) return;
    final name = payload['name'] as String? ?? 'email.eml';
    await _ingestBytes(name, bytes);
  }

  /// Parses raw file [bytes] (an `.eml` or `.html`) and shows the result.
  Future<void> _ingestBytes(String name, Uint8List bytes) async {
    if (!mounted) return;
    if (bytes.length > maxEmailInputBytes) {
      _toast('File is too large to render safely');
      return;
    }
    final revision = ++_loadRevision;
    final EmlMessage message;
    try {
      message = await compute(decodeEmailFile, (name, bytes));
    } catch (error) {
      if (revision == _loadRevision) _toast('Failed to decode $name: $error');
      return;
    }
    if (!mounted || revision != _loadRevision) return;
    final html = message.renderableHtml;
    if (html == null || html.trim().isEmpty) {
      _toast('No HTML or text body found in $name');
      return;
    }

    setState(() {
      _loadedHtml = html;
      _loadedFileName = name;
      _inlineImages = message.inlineImages;
      _allowRemoteImages = false;
    });
  }

  /// Identity for the [HtmlEmailView] key so it rebuilds when the source or
  /// image policy changes.
  String get _currentKey =>
      '${_loadedFileName ?? 'sample-$_selected'}-$_allowRemoteImages';

  Future<void> _openFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['eml', 'html', 'htm'],
        withData: false,
        withReadStream: true,
      );
      if (result == null) return; // cancelled

      final file = result.files.single;
      if (file.size > maxEmailInputBytes) {
        _toast('File is too large to render safely');
        return;
      }
      final revision = ++_loadRevision;
      final bytes =
          file.bytes ??
          await readEmailStream(
            file.readStream ?? file.xFile.openRead(0, maxEmailInputBytes + 1),
          );
      if (!mounted || revision != _loadRevision) return;
      await _ingestBytes(file.name, bytes);
    } catch (e) {
      _toast('Failed to open file: $e');
    }
  }

  Future<void> _dropFiles(DropDoneDetails detail) async {
    if (!mounted) return;
    setState(() => _isDraggingEml = false);

    final emlFiles = detail.files
        .where((file) => file.name.toLowerCase().endsWith('.eml'))
        .toList();
    if (emlFiles.isEmpty) {
      _toast('Drop an .eml file to preview it');
      return;
    }

    final file = emlFiles.first;
    final revision = ++_loadRevision;
    try {
      if (await file.length() > maxEmailInputBytes) {
        if (mounted) _toast('File is too large to render safely');
        return;
      }
      final bytes = await readEmailStream(
        file.openRead(0, maxEmailInputBytes + 1),
      );
      if (!mounted || revision != _loadRevision) return;
      await _ingestBytes(file.name, bytes);
      if (detail.files.length > 1) {
        final ignored = detail.files.length - 1;
        _toast(
          ignored == 1
              ? 'Loaded ${file.name}; ignored 1 other file'
              : 'Loaded ${file.name}; ignored $ignored other files',
        );
      }
    } catch (e) {
      _toast('Failed to open ${file.name}: $e');
    }
  }

  void _setDraggingEml(bool dragging) {
    if (!_canDropFiles || _isDraggingEml == dragging) return;
    setState(() => _isDraggingEml = dragging);
  }

  void _selectSample(int index) {
    _loadRevision++;
    setState(() {
      _selected = index;
      _loadedHtml = null;
      _loadedFileName = null;
      _inlineImages = const {};
      _allowRemoteImages = false;
    });
  }

  HtmlRenderConfig _buildConfig() => HtmlRenderConfig(
    imageResolver: DefaultHtmlImageResolver(
      allowRemoteImages: _allowRemoteImages,
      inlineAttachments: _inlineImages,
    ),
    fitToWidth: _fitToWidth,
    onLinkTap: (url, _) => _toast('Link tapped: $url'),
    onImageTap: (src, _) => _toast('Image tapped: $src'),
    blockedImageBuilder: _buildBlockedImage,
  );

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
  }

  Widget _buildBlockedImage(
    BuildContext context,
    String src,
    Map<String, String> attrs,
  ) {
    return GestureDetector(
      onTap: () => setState(() => _allowRemoteImages = true),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF3E0),
          border: Border.all(color: const Color(0xFFFFCC80)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.download_outlined,
              size: 16,
              color: Color(0xFFE65100),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                attrs['alt']?.isNotEmpty == true
                    ? 'Load image: ${attrs['alt']}'
                    : 'Tap to load image',
                style: const TextStyle(fontSize: 12, color: Color(0xFFE65100)),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('flutter_native_html — email renderer'),
        actions: [
          IconButton(
            tooltip: 'Open .eml / .html file',
            icon: const Icon(Icons.folder_open),
            onPressed: _openFile,
          ),
          Row(
            children: [
              const Text('Remote img', style: TextStyle(fontSize: 12)),
              Switch(
                value: _allowRemoteImages,
                onChanged: (v) => setState(() => _allowRemoteImages = v),
              ),
            ],
          ),
          Row(
            children: [
              const Text('Fit width', style: TextStyle(fontSize: 12)),
              Switch(
                value: _fitToWidth,
                onChanged: (v) => setState(() => _fitToWidth = v),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          _buildSamplePicker(),
          const Divider(height: 1),
          Expanded(
            child: _buildDropTarget(
              SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: HtmlEmailView(
                  // Re-create when source or image policy changes.
                  key: ValueKey(_currentKey),
                  html: _currentHtml,
                  config: _buildConfig(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDropTarget(Widget child) {
    if (!_canDropFiles) return child;
    return DropTarget(
      onDragDone: _dropFiles,
      onDragEntered: (_) => _setDraggingEml(true),
      onDragExited: (_) => _setDraggingEml(false),
      child: Stack(
        fit: StackFit.expand,
        children: [
          child,
          IgnorePointer(
            ignoring: !_isDraggingEml,
            child: AnimatedOpacity(
              opacity: _isDraggingEml ? 1 : 0,
              duration: const Duration(milliseconds: 120),
              child: const _EmlDropOverlay(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSamplePicker() {
    final fileLoaded = _loadedFileName != null;
    return SizedBox(
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        // One extra leading slot for the loaded-file chip when present.
        itemCount: kSampleEmails.length + (fileLoaded ? 1 : 0),
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          if (fileLoaded && index == 0) {
            return InputChip(
              avatar: const Icon(Icons.description_outlined, size: 18),
              label: Text(_loadedFileName!),
              selected: true,
              onDeleted: () => _selectSample(_selected),
              onSelected: (_) {},
            );
          }
          final sampleIndex = fileLoaded ? index - 1 : index;
          return ChoiceChip(
            label: Text(kSampleEmails[sampleIndex].title),
            selected: !fileLoaded && sampleIndex == _selected,
            onSelected: (_) => _selectSample(sampleIndex),
          );
        },
      ),
    );
  }
}

class _EmlDropOverlay extends StatelessWidget {
  const _EmlDropOverlay();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    return DecoratedBox(
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.24)),
      child: Center(
        child: Container(
          width: 420,
          margin: const EdgeInsets.all(24),
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 26),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: color, width: 2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 28,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.mark_email_read_outlined,
                  color: color,
                  size: 34,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Drop .eml file here',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Only email message files are accepted',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
