import SwiftUI
import Contacts
import ContactsUI

/// Import contacts you pick in the system picker. The picker runs outside the app: L1ne gets no Contacts
/// permission and sees only the contacts you tap. Only a name and a SIP address are kept; phone numbers,
/// emails, birthdays and everything else on the card are ignored.
struct SystemContactPicker: UIViewControllerRepresentable {
    var onPick: (VCard.Result) -> Void

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let p = CNContactPickerViewController()
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: CNContactPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick) }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onPick: (VCard.Result) -> Void
        init(_ f: @escaping (VCard.Result) -> Void) { onPick = f }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contacts: [CNContact]) {
            onPick(SystemContacts.convert(contacts))
        }

    }
}
