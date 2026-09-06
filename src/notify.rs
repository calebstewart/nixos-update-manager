use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex, MutexGuard};

use notify_rust::{ActionResponse, Hint, Notification, NotificationHandle, Timeout, Urgency};

use crate::icons::{Icon, Icons};
use crate::state::{PendingUpdate, Progress};
use crate::troubleshoot::Action;
use crate::{ApplyMode, Command};

const APP_NAME: &str = "NixOS Updates";

/// How long a terminal outcome nobody takes down stays up.
const INFO_TIMEOUT: u32 = 5000;

/// Longer than [`INFO_TIMEOUT`]: the blocked notice is the only place the
/// reason is spelled out, and it is shown once per transition, so it is worth
/// a moment more to read than an outcome the tray also carries.
const BLOCKED_TIMEOUT: u32 = 8000;

pub struct Notifier {
    tx: Sender<Command>,
    icons: Arc<Icons>,
    /// The stage in flight: checking, applying. Replaced by the next stage
    /// and closed when the stage ends.
    status: Slot,
    /// The pending update, with its `Build` / `Apply now` button. Closed when
    /// that button stops meaning anything -- the build or apply it offers has
    /// started, or the daemon is going away.
    pending: Slot,
    /// The last failure, with its report buttons. Closed when a later success
    /// clears the failure the buttons would open.
    failure: Slot,
}

/// One live notification the daemon takes back down itself.
///
/// Everything shown with [`Timeout::Never`] is the desktop's forever, so each
/// one is owned by a slot and closed by the transition that makes it obsolete
/// rather than left to pile up. A slot holds at most one notification: showing
/// into a full slot closes what was there, so a stage can never stack two of
/// its own.
#[derive(Clone, Default)]
struct Slot(Arc<Mutex<Held>>);

#[derive(Default)]
struct Held {
    handle: Option<NotificationHandle>,
    /// Bumped by every close. See [`Slot::show`].
    epoch: u64,
}

impl Slot {
    /// A panic while closing one notification is no reason to stop closing the
    /// rest of them, so the poison is stepped over rather than propagated.
    fn lock(&self) -> MutexGuard<'_, Held> {
        self.0.lock().unwrap_or_else(|err| err.into_inner())
    }

    fn epoch(&self) -> u64 {
        self.lock().epoch
    }

    /// Show `n`, taking down whatever this slot was already holding. `None`
    /// when there is nothing to hold: the server refused the notification, or
    /// the `epoch` guard below declined to show it at all.
    ///
    /// That guard is against a close that overtakes the show. The actionable
    /// notifications reach the bus from their own thread, so a `clear` on the
    /// worker thread can legitimately land first -- and a notification whose
    /// withdrawal has already happened must then never appear, rather than
    /// appear un-withdrawable. Pass `None` from the worker thread itself,
    /// where the ordering is just the call order.
    fn show(&self, epoch: Option<u64>, n: &Notification) -> Option<u32> {
        let mut slot = self.lock();
        if epoch.is_some_and(|epoch| epoch != slot.epoch) {
            return None;
        }
        let handle = match n.show() {
            Ok(handle) => handle,
            Err(err) => {
                log::warn!("notification failed: {err}");
                return None;
            }
        };
        let id = handle.id();
        let previous = slot.handle.replace(handle);
        // The old handle is closed outside the guard: `close` is a blocking
        // D-Bus round trip, and no other slot user should wait on it.
        drop(slot);
        if let Some(previous) = previous {
            previous.close();
        }
        Some(id)
    }

    fn close(&self) {
        let handle = {
            let mut slot = self.lock();
            slot.epoch += 1;
            slot.handle.take()
        };
        if let Some(handle) = handle {
            handle.close();
        }
    }

    /// Take the notification down if it is still the one this slot holds. Used
    /// where an action wait has ended: closing an id the server has already
    /// forgotten is a no-op, so this covers both endings -- a button pressed,
    /// and a dismissal we were only told about -- while a newer notification
    /// that has since replaced it is left alone.
    fn done(&self, id: u32) {
        let handle = {
            let mut slot = self.lock();
            match slot.handle.as_ref() {
                Some(handle) if handle.id() == id => slot.handle.take(),
                _ => None,
            }
        };
        if let Some(handle) = handle {
            handle.close();
        }
    }
}

/// Whether the server draws action buttons at all. A server without them still
/// gets the notification, just without the shortcut; the tray carries the same
/// entries either way.
fn actions_supported() -> bool {
    notify_rust::get_capabilities()
        .map(|caps| caps.iter().any(|c| c == "actions"))
        .unwrap_or(false)
}

/// Show an actionable notification into `slot` and block this thread until the
/// user presses one of its buttons or it goes away.
///
/// The handle stays *in the slot* rather than being consumed by the wait, which
/// is the whole point: `NotificationHandle::wait_for_action` takes it by value,
/// and then nothing could take the notification down when it went stale.
/// `notify_rust::handle_action` waits on the id instead, over its own
/// connection, and returns on either `ActionInvoked` or `NotificationClosed` --
/// so a close from the worker thread ends this wait too.
///
/// `epoch` is the slot's, read on the worker thread before this one was
/// spawned; a close since then means the offer is already off the table and
/// nothing is shown at all.
fn watch(slot: &Slot, epoch: u64, n: &Notification, actions: bool, on_action: impl FnOnce(&str)) {
    let Some(id) = slot.show(Some(epoch), n) else {
        return;
    };
    if !actions {
        // Nothing to wait for, but the slot keeps the handle: a notification
        // with no buttons still has to be closable when it stops being true.
        return;
    }
    if let Err(err) = notify_rust::handle_action(id, |response| {
        if let ActionResponse::Custom(action) = response {
            on_action(action);
        }
    }) {
        log::warn!("waiting on notification actions failed: {err}");
    }
    slot.done(id);
}

/// The one notification that changes in place: the build's progress bar. The
/// handle is what lets it be replaced rather than stacked, and closed when the
/// build ends so the "ready to apply" (or failure) notification that follows
/// is the only one left standing.
///
/// The `value` hint is the freedesktop convention for a progress bar (0-100),
/// which some notification daemons draw as a ring around the icon; the body text carries the
/// same numbers for a server that ignores it.
pub struct ProgressNotification {
    handle: NotificationHandle,
    icons: Arc<Icons>,
}

impl ProgressNotification {
    fn fill(n: &mut Notification, icons: &Icons, progress: &Progress) {
        n.body(&progress.detail())
            .icon(&icons.notify_icon(Icon::building(progress.fraction())))
            .hint(Hint::CustomInt(
                "value".to_string(),
                i32::from(progress.percent()),
            ));
    }

    pub fn update(&mut self, progress: &Progress) {
        Self::fill(&mut self.handle, &self.icons, progress);
        if let Err(err) = self.handle.update() {
            log::warn!("progress notification update failed: {err}");
        }
    }

    pub fn close(self) {
        self.handle.close();
    }
}

impl Notifier {
    pub fn new(tx: Sender<Command>, icons: Arc<Icons>) -> Self {
        Self {
            tx,
            icons,
            status: Slot::default(),
            pending: Slot::default(),
            failure: Slot::default(),
        }
    }

    /// Notifications draw the same art as the tray, so the two agree about what
    /// state the daemon is in. `Icons` hands back an absolute path when it has
    /// our own PNG and a theme name otherwise.
    fn base(icons: &Icons, icon: Icon, summary: &str, body: &str) -> Notification {
        let mut n = Notification::new();
        n.appname(APP_NAME)
            .summary(summary)
            .body(body)
            .icon(&icons.notify_icon(icon));
        n
    }

    /// Transient informational notification: an outcome, said once. Nobody
    /// takes these down, so they expire on their own.
    pub fn info(&self, summary: &str, body: &str) {
        let result = Self::base(&self.icons, Icon::UpToDate, summary, body)
            .timeout(Timeout::Milliseconds(INFO_TIMEOUT))
            .show();
        if let Err(err) = result {
            log::warn!("notification failed: {err}");
        }
    }

    /// A stage that is under way: checking, applying. Deliberately *not* on a
    /// timeout -- it says "still working", so any timeout either lies about the
    /// stage ending or outlives it -- and taken down by
    /// [`Notifier::clear_status`] the moment it does. `Transient` because a
    /// stage that is over has no business in the notification centre either:
    /// closing it should leave nothing behind.
    pub fn status(&self, icon: Icon, summary: &str, body: &str) {
        let mut n = Self::base(&self.icons, icon, summary, body);
        n.timeout(Timeout::Never).hint(Hint::Transient(true));
        let _ = self.status.show(None, &n);
    }

    /// The stage ended. Whatever follows -- the outcome, a failure -- is its
    /// own notification.
    pub fn clear_status(&self) {
        self.status.close();
    }

    /// The checkout has local changes. Nobody takes this one down: the tray
    /// keeps saying so for as long as it is true, and it is only shown on the
    /// transition, so it expires like `info` under its own icon.
    pub fn blocked(&self, reason: &str) {
        let result = Self::base(&self.icons, Icon::Blocked, "Update blocked", reason)
            .timeout(Timeout::Milliseconds(BLOCKED_TIMEOUT))
            .show();
        if let Err(err) = result {
            log::warn!("notification failed: {err}");
        }
    }

    /// Persistent error notification, for the errors nothing can be done about
    /// from here. A failure the worker recorded a report for goes through
    /// [`Notifier::failure`] instead.
    ///
    /// No timeout, and none would be honoured: `Critical` is the one urgency
    /// the major servers refuse to expire on their own. Nor is there a stage
    /// whose end withdraws these -- they report something that already
    /// happened, so they stand until the user dismisses them.
    pub fn error(&self, summary: &str, body: &str) {
        let result = Self::base(&self.icons, Icon::Error, summary, body)
            .urgency(Urgency::Critical)
            .timeout(Timeout::Never)
            .show();
        if let Err(err) = result {
            log::warn!("notification failed: {err}");
        }
    }

    /// The build's progress. Shown once; the returned handle is updated in
    /// place from then on. `None` when the server refused it, in which case
    /// the tray is the only progress display.
    pub fn progress(&self, progress: &Progress) -> Option<ProgressNotification> {
        let mut n = Self::base(
            &self.icons,
            Icon::building(progress.fraction()),
            "Building update",
            "",
        );
        // Same bargain as `status`: never expires, always closed by us, and
        // never kept in the notification centre once it is.
        n.timeout(Timeout::Never).hint(Hint::Transient(true));
        ProgressNotification::fill(&mut n, &self.icons, progress);
        match n.show() {
            Ok(handle) => Some(ProgressNotification {
                handle,
                icons: self.icons.clone(),
            }),
            Err(err) => {
                log::warn!("progress notification failed: {err}");
                None
            }
        }
    }

    /// A failed check, build or apply: a persistent error notification plus the
    /// two entries the tray menu grows, so the report is one click away without
    /// going to the tray. Persistent because it is a question -- which is also
    /// why it has to be withdrawn when the answer stops mattering; see
    /// [`Notifier::clear_failure`]. The action wait blocks, so this lives on
    /// its own thread.
    pub fn failure(&self, summary: String, body: String) {
        let tx = self.tx.clone();
        let icons = self.icons.clone();
        let slot = self.failure.clone();
        let epoch = slot.epoch();
        std::thread::spawn(move || {
            let actions = actions_supported();

            let mut n = Self::base(&icons, Icon::Error, &summary, &body);
            n.urgency(Urgency::Critical).timeout(Timeout::Never);
            if actions {
                n.action("report", "Open report");
                n.action("claude", "Troubleshoot");
            }

            watch(&slot, epoch, &n, actions, |action| {
                let action = match action {
                    "report" => Some(Action::Report),
                    "claude" => Some(Action::Claude),
                    _ => None,
                };
                if let Some(action) = action {
                    let _ = tx.send(Command::Troubleshoot(action));
                }
            });
        });
    }

    /// The recorded failure is gone -- a later check, build or apply
    /// succeeded -- so both buttons now point at nothing: `Worker::troubleshoot`
    /// would log and return, and the tray has already dropped the same two
    /// entries.
    pub fn clear_failure(&self) {
        self.failure.close();
    }

    /// The persistent "there is an update" notification, in the shape the
    /// update is in: unbuilt, with the plan and a "Build" action; or built,
    /// with the closure summary and an "Apply now" action. Either action is
    /// exactly what the tray entry of the same name sends. The action wait
    /// blocks, so the whole notification lives on its own short-lived thread.
    ///
    /// One update, one notification: showing the built shape closes the unbuilt
    /// one it supersedes, because both live in the same slot.
    pub fn updates_available(&self, pending: &PendingUpdate) {
        let built = pending.built();
        let (summary, body, action_label) = if built {
            (
                "Update ready to apply",
                format!(
                    "{}\n{}",
                    pending.summary.short(),
                    pending.summary.breakdown()
                ),
                "Apply now",
            )
        } else {
            let plan = pending
                .plan
                .map(|plan| plan.describe())
                .unwrap_or_else(|| "Build plan unavailable".to_string());
            (
                "Updates available",
                format!("{}\n{plan}", pending.summary.short()),
                "Build",
            )
        };

        let tx = self.tx.clone();
        let icons = self.icons.clone();
        let slot = self.pending.clone();
        let epoch = slot.epoch();
        std::thread::spawn(move || {
            let actions = actions_supported();

            let mut n = Self::base(&icons, Icon::UpdatesAvailable, summary, &body);
            n.timeout(Timeout::Never);
            if actions {
                n.action("go", action_label);
            }

            watch(&slot, epoch, &n, actions, |action| {
                if action == "go" {
                    let command = if built {
                        Command::Apply(ApplyMode::Full)
                    } else {
                        Command::Build
                    };
                    let _ = tx.send(command);
                }
            });
        });
    }

    /// The offer on the pending notification has been taken up (or overtaken):
    /// the build or apply it proposes is starting, so its button would only
    /// queue a command the worker refuses. Under `autoBuild` this lands before
    /// the notification is even on screen, and the epoch guard in [`Slot::show`]
    /// means it is not shown at all -- which is right, since the daemon is
    /// already doing the one thing it would have offered.
    pub fn clear_pending(&self) {
        self.pending.close();
    }

    /// The daemon is going away. Every notification it holds open has a button
    /// wired to a channel nobody is left to read, so none of them outlive it.
    pub fn close_all(&self) {
        self.status.close();
        self.pending.close();
        self.failure.close();
    }
}
