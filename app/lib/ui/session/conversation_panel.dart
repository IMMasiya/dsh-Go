// The side panel with a conversation open: a row of panes to pick from, the pane, and
// the shortcuts as a row of keys at the foot.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/quick_panel_state.dart';
import '../shell/drawer/drawer_destination.dart';
import '../shell/quick_panel.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'conversation_panes.dart';
import 'session_detail_page.dart';

/// The pane last picked; the same one comes back, in any conversation that has it.
class ConversationPaneController extends Notifier<String> {
  @override
  String build() => ConversationPane.overview.id;

  void select(String id) => state = id;
}

final conversationPaneProvider = NotifierProvider<ConversationPaneController, String>(ConversationPaneController.new);

class ConversationPanel extends ConsumerWidget {
  const ConversationPanel({super.key, required this.sessionId, required this.onOpen});

  final String sessionId;
  final ValueChanged<DrawerDestination> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final panes = ConversationPane.shownFor(ref, sessionId);
    final picked = ref.watch(conversationPaneProvider);
    final pane = panes.where((p) => p.id == picked).firstOrNull ?? panes.first;
    final destinations = ref.watch(quickPanelProvider.select((p) => p.items));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final p in panes)
                        _Key(
                          key: ValueKey('pane-${p.id}'),
                          icon: p.icon,
                          label: p.label(),
                          selected: p == pane,
                          onTap: () {
                            HapticFeedback.selectionClick();
                            ref.read(conversationPaneProvider.notifier).select(p.id);
                          },
                        ),
                    ],
                  ),
                ),
              ),
              _Key(
                key: const ValueKey('pane-open-full'),
                icon: AppIcons.openExternal,
                label: l10n.shellPanelOpenFull,
                onTap: () => SessionDetailPage.open(context, sessionId, tab: pane.tab),
              ),
            ],
          ),
        ),
        Expanded(
          // Not the chat's scroll controller, which a tap on the status bar goes to.
          child: PrimaryScrollController.none(
            child: AnimatedSwitcher(
              duration: AppMotion.of(context, AppMotion.quick),
              child: KeyedSubtree(key: ValueKey('$sessionId/${pane.id}'), child: pane.build(sessionId)),
            ),
          ),
        ),
        if (destinations.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (final destination in destinations)
                  _Key(
                    key: ValueKey('quick-panel-${destination.name}'),
                    icon: destination.icon,
                    label: destination.label(l10n),
                    onTap: () => onOpen(destination),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({super.key, required this.icon, required this.label, required this.onTap, this.selected = false});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: Tooltip(
        message: label,
        child: InkResponse(
          onTap: onTap,
          radius: 22,
          child: AnimatedContainer(
            duration: AppMotion.of(context, AppMotion.quick),
            curve: AppMotion.std,
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: selected ? colors.onSurface.withValues(alpha: 0.08) : Colors.transparent,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 20, color: selected ? colors.primary : colors.onSurfaceVariant),
          ),
        ),
      ),
    );
  }
}
