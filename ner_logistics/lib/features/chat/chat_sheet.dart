import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/connectivity_provider.dart';
import '../../shared/widgets/glass_surface.dart';
import '../../theme/colors.dart';
import '../auth/application/auth_controller.dart';
import '../ml/application/ml_providers.dart';
import '../ml/presentation/ml_widgets.dart';
import 'chat_controller.dart';

const _starters = [
  'Which route is riskiest today?',
  'Where is the risk on NH-10?',
  'Show the top high-risk segments',
];

/// Floating button for every role shell. Hidden when signed out: the assistant
/// only answers as a signed-in user.
class ChatButton extends ConsumerWidget {
  const ChatButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(authRoleProvider) == null) return const SizedBox.shrink();
    return FloatingActionButton.extended(
      heroTag: 'ner-assistant',
      backgroundColor: AppColors.navy900,
      foregroundColor: Colors.white,
      icon: const Icon(Icons.chat_bubble_outline),
      label: const Text('Assistant'),
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        builder: (_) => const ChatSheet(),
      ),
    );
  }
}

/// Labelled "advisory" on purpose (WEB-007, same as the web ChatPanel): every
/// answer comes from the same RPCs the rest of the app shows, and never orders
/// anyone to act.
class ChatSheet extends ConsumerStatefulWidget {
  const ChatSheet({super.key});

  @override
  ConsumerState<ChatSheet> createState() => _ChatSheetState();
}

class _ChatSheetState extends ConsumerState<ChatSheet> {
  final _draft = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _draft.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _submit(String text) {
    if (text.trim().isEmpty) return;
    _draft.clear();
    ref
        .read(chatControllerProvider.notifier)
        .send(text, chatLanguage(Localizations.localeOf(context)));
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatControllerProvider);
    final online = ref.watch(isOnlineProvider).valueOrNull ?? true;
    final meta = ref.watch(mlStatusProvider).valueOrNull;

    ref.listen(chatControllerProvider, (_, _) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    });

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.8,
        child: GlassSurface(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                child: Row(
                  children: [
                    const Text(
                      'Assistant',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Advisory',
                      style: TextStyle(fontSize: 12, color: AppColors.slate500),
                    ),
                    const Spacer(),
                    if (meta != null) MlStateChip(meta: meta),
                    IconButton(
                      tooltip: 'New conversation',
                      icon: const Icon(Icons.refresh),
                      onPressed: chat.messages.isEmpty
                          ? null
                          : ref.read(chatControllerProvider.notifier).reset,
                    ),
                    IconButton(
                      tooltip: 'Close',
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: chat.messages.isEmpty
                    ? ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          const Text(
                            'Ask about route risk and alerts. Answers come from live data and the ML model; '
                            'verify on the ground before acting.',
                            style: TextStyle(color: AppColors.slate500),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final s in _starters)
                                ActionChip(
                                  label: Text(s),
                                  onPressed: online ? () => _submit(s) : null,
                                ),
                            ],
                          ),
                        ],
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(12),
                        itemCount: chat.messages.length,
                        itemBuilder: (_, i) => _Bubble(
                          message: chat.messages[i],
                          thinking:
                              chat.thinking && i == chat.messages.length - 1,
                        ),
                      ),
              ),
              if (chat.error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Text(
                    chat.error!,
                    style: const TextStyle(color: AppColors.signalRed700),
                  ),
                ),
              if (!online)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text(
                    'Assistant needs a connection. Cached route risk still works.',
                    style: TextStyle(color: AppColors.slate500),
                  ),
                ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _draft,
                          enabled: online && !chat.streaming,
                          minLines: 1,
                          maxLines: 4,
                          maxLength: 1000,
                          textInputAction: TextInputAction.send,
                          onSubmitted: _submit,
                          decoration: const InputDecoration(
                            hintText: 'Ask about routes or risk…',
                            counterText: '',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      chat.streaming
                          ? IconButton(
                              tooltip: 'Stop',
                              icon: const Icon(Icons.stop_circle_outlined),
                              onPressed: ref
                                  .read(chatControllerProvider.notifier)
                                  .stop,
                            )
                          : IconButton(
                              tooltip: 'Send',
                              icon: const Icon(Icons.send),
                              color: AppColors.navy900,
                              onPressed: online
                                  ? () => _submit(_draft.text)
                                  : null,
                            ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final ChatMessage message;
  final bool thinking;
  const _Bubble({required this.message, required this.thinking});

  @override
  Widget build(BuildContext context) {
    final mine = message.role == 'user';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.8,
        ),
        decoration: BoxDecoration(
          color: mine ? AppColors.navy900 : AppColors.cardSurface,
          borderRadius: BorderRadius.circular(12),
          border: mine ? null : Border.all(color: AppColors.hairline),
        ),
        child: thinking && message.content.isEmpty
            ? const Text(
                'Checking the data…',
                style: TextStyle(color: AppColors.slate500),
              )
            : SelectableText(
                message.content,
                style: TextStyle(color: mine ? Colors.white : null),
              ),
      ),
    );
  }
}
