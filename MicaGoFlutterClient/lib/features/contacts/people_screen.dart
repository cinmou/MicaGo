import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'contacts_service.dart';

/// People tab: minimal control surface for read-only local contacts matching.
/// Not an address book — it manages the opt-in and shows matching status.
class PeopleScreen extends StatelessWidget {
  const PeopleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final contacts = context.watch<ContactsService>();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.contacts_outlined),
                    const SizedBox(width: 8),
                    Text('Contacts matching',
                        style: Theme.of(context).textTheme.titleMedium),
                    const Spacer(),
                    _StatusChip(status: contacts.status),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Match chat phone numbers and emails to names from this '
                  'device\'s contacts. Read-only and local — contacts are never '
                  'modified or uploaded.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                _Action(contacts: contacts),
              ],
            ),
          ),
        ),
        if (contacts.status == ContactsStatus.ready) ...[
          const SizedBox(height: 12),
          Text('${contacts.contacts.length} contacts available for matching',
              style: Theme.of(context).textTheme.bodySmall),
        ],
        if (contacts.error != null) ...[
          const SizedBox(height: 12),
          Text(contacts.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
      ],
    );
  }
}

class _Action extends StatelessWidget {
  final ContactsService contacts;
  const _Action({required this.contacts});

  @override
  Widget build(BuildContext context) {
    switch (contacts.status) {
      case ContactsStatus.requesting:
        return const Center(child: CircularProgressIndicator());
      case ContactsStatus.ready:
        return OutlinedButton.icon(
          onPressed: contacts.disable,
          icon: const Icon(Icons.link_off),
          label: const Text('Turn off contacts matching'),
        );
      case ContactsStatus.denied:
        return Row(
          children: [
            FilledButton.icon(
              onPressed: contacts.enable,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: contacts.openSettings,
              child: const Text('Open Settings'),
            ),
          ],
        );
      case ContactsStatus.disabled:
        return FilledButton.icon(
          onPressed: contacts.enable,
          icon: const Icon(Icons.contacts),
          label: const Text('Enable contacts matching'),
        );
    }
  }
}

class _StatusChip extends StatelessWidget {
  final ContactsStatus status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final (String label, Color color) = switch (status) {
      ContactsStatus.ready => ('On', Colors.green),
      ContactsStatus.requesting => ('Requesting…', Theme.of(context).colorScheme.tertiary),
      ContactsStatus.denied => ('Denied', Theme.of(context).colorScheme.error),
      ContactsStatus.disabled => ('Off', Theme.of(context).colorScheme.outline),
    };
    return Chip(
      label: Text(label),
      visualDensity: VisualDensity.compact,
      side: BorderSide(color: color),
    );
  }
}
