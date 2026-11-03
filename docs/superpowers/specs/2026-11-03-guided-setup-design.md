# Guided setup and private-network pairing

## Intent

Make a fresh two-computer setup understandable without separate instructions. The user stopped testing 0.1.3 because the current pages crowd unrelated buttons together, hide installation details, make required actions appear optional, and leave file transfer and recovery storage unexplained. They explicitly chose automatic network pairing as part of the redesign.

Keep the existing WPF/.NET Framework 4.8 desktop and pinned PowerShell engine. This is a proposed 0.2.0 development milestone; no release, merge or live system changes are authorized by this document.

## Approaches

1. Restyle the current pages and retain file exchange. Smallest change, but leaves the central connection friction. The user chose automatic pairing instead.
2. Guide each required action on its own page, automatically exchange existing pairing messages over a private network, and preserve explicit security confirmations. Recommended and selected direction.
3. Replace the setup/security stack or add a hosted account service. Unnecessary for self-hosted backups and outside this redesign.

## Wizard

The flow is computer role, folders/mode, software review, preparation progress, server recovery export, private connection, identity confirmation, verified sample, and completion. Source and server show role-specific instructions; recovery export is server-only.

Use a persistent checklist with Completed, Current and Waiting states. Each subpage has one prominent next action, a consistent Back position and separated secondary/help actions. Show the other computer's next action explicitly while waiting. Required steps cannot look like optional utilities. Keep disabled actions explained, errors beside the relevant action, and keyboard/screen-reader navigation usable. Use generous spacing and wrapping at the existing minimum window size.

Mechanical checks run automatically on entry or after their prerequisite succeeds. Continue advances after a successful result; it must not duplicate a separate unexplained check. Automatically verify repository reachability after pairing and run the source's sample backup/restore after the user chooses to finish setup. The server can finish its local setup while visibly waiting for that source sample, without claiming the sample already passed.

Saved choices can resume setup; they are not proof that an old network connection, software verification or sample remains valid. Hydrate pairing status from the owning backend rather than retaining an old code after an error. Reuse an existing unexpired pairing session on retry; replacing an accepted pending identity requires an explicit Start again action.

## Software approval and progress

Before any download or installation, show the exact catalog-selected software, versions, purpose, source/license, install location and scope. Source needs PowerShell and Restic. Folder server adds RestServer, Python and bcrypt; Media server also adds FFmpeg/FFprobe and Pillow. Explain private pinned copies honestly; existing system versions are not silently reused or replaced.

The read-only plan must run under Windows PowerShell 5.1 before bootstrap acquisition. Include bootstrap and runtime PowerShell copies in the review. Require explicit acceptance of the reviewed plan and an Install and prepare action. Bind acceptance to role, mode, folder and catalog package identities; changing them invalidates approval. Check again is read-only.

Show checking, downloading, verifying, extracting, ready/reused and failed states per package. Show package/stage progress without inventing byte percentages. Preserve completed rows when another package fails. Use bounded structured progress, never arbitrary tool stderr or secret-bearing output. Retrying refreshes the plan and clearly states remaining work.

NetBird has its own optional consent page. Opening an existing installation is distinct from installing its system service with administrator approval. Existing private VPN/LAN remains supported. Explain background task/shortcut creation and later scoped network permissions before they occur.

## Folders and OneDrive

Start folder pickers at the physical computer/drives view or a suitable local user folder, with an editable full path and a visible resolved selection. Suggest ordinary local folders for app state and repositories; retain strict link, overlap and placeholder protections.

Display which selected path or ancestor is unsupported and an actionable ordinary-folder alternative. OneDrive redirection is not a reason to disable the user's OneDrive or silently move Desktop/Documents. NetCrate must not alter those Windows settings during setup.

## Recovery

Give recovery its own page. Default Save recovery file to a writable ordinary location under the user's profile, outside application state and selected backup storage. C: is supported; another physical drive is not a prerequisite. Show the exact saved location and Show file. Preserve existing recovery files and offer a new filename rather than letting an overwrite prompt lead to a generic CreateNew failure.

Offer an explicit Copy recovery contents alternative containing the complete compatible recovery document, suitable for a password manager or private document. Clipboard success is not proof of a saved copy. Exclude copied keys from Windows clipboard history and cloud synchronization using documented DWORD-zero formats, clear after two minutes only while NetCrate still owns that clipboard content, and provide Clear now. Explain that clipboard contents are sensitive without showing the keys in ordinary status or logs.

Keep plaintext out of SetupState, generic action results, input JSON, progress, logs and command-line arguments. A dedicated ephemeral export interface carries it only to the clipboard action. Provide a compatible Paste recovery details path in independent recovery so users can recover without manually reconstructing a file.

Distinguish Saved locally from Separate copy confirmed. Offer a clear Continue with local copy choice when that is all the user can do; explain that losing this PC and that copy would prevent recovery. Do not label a local save as an independently protected copy. Recommend separate accessible storage without forcing a USB drive or a particular cloud service.

## Automatic network pairing

Automate transport of the existing signed request and recipient-encrypted signed reply. Do not replace the cryptographic protocol, trust computers merely because they share a VPN, remove either existing code comparison, or send repository secrets before the current confirmation gates.

The source selects the Backup Server from available NetBird peers when possible, with an explicit private-address option for an existing VPN/LAN. The server selects or confirms the intended source peer/address before enabling reception; this makes the initial firewall permission specific to one peer. Inspect the local NetBird CLI's bounded `status --json` output, not its management API or account credentials. Check the pinned 0.81.3 output shape and offer manual addresses when discovery is unavailable. A discovered name is a hint, not verified identity. No public listener, router configuration, broadcast of private keys, or new hosted service.

Use a temporary listener bound to one selected private IPv4 address on a dedicated setup port, proposed TCP 8201. Use the server TLS identity that the existing reply later pins; separate creation of that public certificate from activation of repository credentials. The source holds the presented certificate as pending session evidence, then verifies it matches the certificate authenticated by the existing encrypted reply before final confirmation. Do not modify certificate stores or global TLS validation.

Show a device-code comparison on both computers before the server accepts the source identity. After confirmed encrypted reply delivery, show the existing connection-code comparison on both. Explain what each comparison verifies and what to do when it differs. Then run the current repository/acknowledgment checks automatically. Normal setup exchanges no files. Keep manual file exchange in an explicitly explained fallback with clear sender/recipient and transfer instructions.

Require explicit approval before creating a temporary inbound firewall rule. Scope it to the selected local and intended source addresses, setup port and verified program. Preserve the existing separate rest-server TCP 8200 rule. A desktop-owned helper stops on cancellation, close, timeout or parent death. A separate elevated lease guardian removes only its verified owned rule on cancellation, desktop death or the 15-minute deadline. Forced guardian termination or power loss can leave a stale narrow rule; the next setup must reconcile matching owned stale rules before listening. No listener restarts implicitly after reboot. Existing unrelated rules must never be deleted or broadened to make setup work.

Use length-prefixed UTF-8 JSON with a 128 KiB frame limit, duplicate/case-colliding field rejection, five-second connect/handshake deadlines and a fifteen-second frame deadline. Allow one active exchange and one accepted pending session during a fixed 15-minute listener lease; poll with one-to-ten-second bounded backoff. Check the accepted socket peer and signed request address against the chosen source address. Exact request repeats return existing status or the same cached sealed reply without re-importing or resetting confirmation. Different requests cannot replace the pending identity. Add an owner/installation mutex around all pairing mutations, including file fallback.

Reject unexpected/competing peers, replay, expired sessions, wrong recipients and changed certificates. Closing/cancelling returns to an honest unpaired/waiting state and preserves existing backups and keys. Resume revalidates backend evidence and explicitly requests a new transport lease; it does not silently open a port. Permanent runtime settings activate only through existing validated pairing actions.

## Validation

Exercise real plan/consent gates before bootstrap, role/mode package selection, truthful progress and retry, every visible pairing substate, stale-state invalidation and resume, local recovery export, no accidental overwrite, clipboard flags/expiry/no later-clipboard deletion, paste recovery and absence of secret persistence.

Use generated identities and repositories for bounded loopback transport tests covering correct pairing, mismatched codes, certificate changes, wrong peer, competing sessions, replay, expiry, timeout, cancellation and cleanup. Simulate firewall helper operations without changing live rules. Existing backup/recovery/retention and version/package checks remain required. Separate computers, real firewall approval, separate administrator accounts and network interruption require recorded physical acceptance; local tests do not establish those results.

## Implementation boundaries

Reuse active engine code, not the unused legacy host-probing preparation module. Split presentation/state, software planning/progress, network transport/lifecycle and ephemeral recovery export into focused components. The builder may settle normal control sizes, copy, internal type names and serialization details while preserving these behaviors. Existing stored backups, keys and pairing formats remain compatible.
