/// The public pages the stores ask every app to link to (SPEC §4.5, §4.9,
/// §4.10), served by the game's own server from `PRIVACY.md`.
///
/// Fixed rather than derived from the configurable server address: the policy
/// describes the production service, and a build pointed at a laptop for
/// testing should still show the policy the store listing names.
abstract final class LegalLinks {
  static final Uri privacy = Uri.parse('https://arco.fly.dev/privacy');
  static final Uri support = Uri.parse('https://arco.fly.dev/support');
}
