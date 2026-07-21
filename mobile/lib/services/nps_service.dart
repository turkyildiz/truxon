import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../i18n.dart';
import 'api.dart';
import 'diag.dart';

/// Quarterly driver-NPS prompt (2 questions: 0–10 + optional comment).
/// Asks once per quarter; "Later" snoozes for 3 days so it nags gently, not
/// constantly. Answers are anonymous to dispatch — the office only sees
/// aggregates and unattributed comments.
class NpsService {
  static const _kSnoozeKey = 'nps_snoozed_until';

  /// Best-effort: never throws, never blocks app use.
  static Future<void> checkAndPrompt(BuildContext context, CompanionApi api) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final snoozedUntil = prefs.getString(_kSnoozeKey);
      if (snoozedUntil != null &&
          DateTime.tryParse(snoozedUntil)?.isAfter(DateTime.now()) == true) {
        return;
      }
      if (await api.npsAnswered()) return;
      if (!context.mounted) return;

      int? score;
      final commentCtl = TextEditingController();
      final submitted = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setState) => AlertDialog(
            title: Text(tr('npsTitle')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('npsQuestion')),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (var n = 0; n <= 10; n++)
                      ChoiceChip(
                        label: Text('$n'),
                        selected: score == n,
                        onSelected: (_) => setState(() => score = n),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: commentCtl,
                  maxLines: 2,
                  decoration: InputDecoration(
                    hintText: tr('npsCommentHint'),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(tr('npsLater')),
              ),
              FilledButton(
                onPressed: score == null ? null : () => Navigator.pop(ctx, true),
                child: Text(tr('npsSubmit')),
              ),
            ],
          ),
        ),
      );

      if (submitted == true && score != null) {
        await api.submitNps(score!, commentCtl.text);
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(tr('npsThanks'))));
        }
      } else {
        await prefs.setString(
            _kSnoozeKey, DateTime.now().add(const Duration(days: 3)).toIso8601String());
      }
    } catch (e) {
      Diag.log('nps: prompt failed: $e');
    }
  }
}
