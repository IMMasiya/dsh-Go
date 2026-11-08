// What her full-mode conversation is waiting on the person for, answered right
// here in 伙伴小屋: an approval for something she wants to do, or a question she
// asked with the ask tool. The cards are the main chat's own (the same buttons,
// the same risk confirmation, the same answers sent back), drawn on her deep
// glass so they belong to the room instead of sending the person elsewhere.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/chat_state.dart';
import '../chat/tool_view.dart';
import '../chat/widgets/approval_card.dart';
import '../chat/widgets/question_card.dart';
import '../theme/motion.dart';
import '../theme/surfaces.dart';
import 'companion_chrome.dart';

/// The approval or question her session [sessionId] is waiting on, or nothing.
/// An approval comes first: the turn can't go on without it.
class CompanionAsk extends ConsumerWidget {
  const CompanionAsk({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asking = ref.watch(
      chatProvider(sessionId)
          .select((s) => (approval: s.openApproval, question: s.questions.firstOrNull, autoApprove: s.autoApprove)),
    );
    final chat = ref.read(chatProvider(sessionId).notifier);
    final approval = asking.approval;
    final question = asking.question;
    Widget? card;
    if (approval != null) {
      card = ApprovalCard(
        key: ValueKey('approval-${approval.eventId}'),
        request: approval,
        view: _viewFor(ref.read(chatProvider(sessionId)).items, approval),
        onRespond: chat.respond,
        // Already trusting the whole conversation: nothing wider to offer.
        onAllowAll: asking.autoApprove ? null : chat.allowAll,
      );
    } else if (question != null) {
      card = QuestionCard(
        key: ValueKey('question-${question.eventId}'),
        request: question,
        onAnswer: (request, answers) => chat.answer(request, answers),
        onReject: chat.rejectQuestion,
      );
    }
    return AnimatedSwitcher(
      duration: AppMotion.of(context, AppMotion.standard),
      switchInCurve: AppMotion.enter,
      switchOutCurve: AppMotion.exit,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SizeTransition(sizeFactor: animation, alignment: Alignment.bottomCenter, child: child),
      ),
      child: card == null
          ? const SizedBox(key: ValueKey('nothing'), width: double.infinity)
          : Padding(
              key: card.key,
              padding: const EdgeInsets.only(bottom: 8),
              child: ConstrainedBox(
                // A long command or a plan to review scrolls inside; she stays in view.
                constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.5),
                child: SingleChildScrollView(child: CompanionDeepCards(child: card)),
              ),
            ),
    );
  }

  /// The tool call the approval is about: its command or path is the card's body.
  static ToolView? _viewFor(List<ChatItem> items, ApprovalRequest request) {
    for (final item in items.reversed) {
      if (item is! ToolChatItem) continue;
      if (item.pendingApproval?.eventId == request.eventId ||
          (request.callId != null && item.callId == request.callId)) {
        return ToolView.of(item);
      }
    }
    return null;
  }
}

/// The app's cards (approval, question) on the room's deep glass instead of
/// the chat's: the same widgets, in water.
class CompanionDeepCards extends StatelessWidget {
  const CompanionDeepCards({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surfaces = DshSurfaces.of(context);
    final deep = companionDeepGlass(context);
    return Theme(
      data: theme.copyWith(
        extensions: [
          ...theme.extensions.values.where((e) => e is! DshSurfaces),
          surfaces.copyWith(
            card: surfaces.card.copyWith(fill: deep.fill, fallbackFill: deep.fallbackFill),
          ),
        ],
      ),
      child: child,
    );
  }
}
