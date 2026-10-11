#!/usr/bin/env python3

from __future__ import annotations

import codecs
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import threading
from dataclasses import dataclass

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")

from gi.repository import Adw, Gdk, Gio, GLib, Gtk


APP_ID = "io.github.pedrocarv.AirPlayMirror"


def find_engine() -> str:
    explicit = os.environ.get("AIRPLAY_ENGINE")
    app_dir = Path(__file__).resolve().parent
    candidates = (
        explicit,
        str(app_dir / "airplay-engine"),
        str(app_dir / "doubletake"),
        shutil.which("airplay-engine"),
        shutil.which("doubletake"),
    )
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return candidate
    return explicit or "airplay-engine"


DOUBLETAKE = find_engine()


CSS = r"""
window {
  background: @window_bg_color;
}

.airplay-hero {
  background-image: linear-gradient(135deg, #4834d4, #6c5ce7 48%, #0984e3);
  border-radius: 24px;
  padding: 26px;
  color: white;
}

.airplay-hero .title-1,
.airplay-hero .title-3,
.airplay-hero .caption {
  color: white;
}

.airplay-hero .caption {
  opacity: 0.84;
}

.hero-icon {
  background: rgba(255, 255, 255, 0.16);
  border: 1px solid rgba(255, 255, 255, 0.22);
  border-radius: 18px;
  padding: 14px;
}

.status-pill {
  background: alpha(@card_bg_color, 0.24);
  border: 1px solid rgba(255, 255, 255, 0.28);
  border-radius: 999px;
  padding: 7px 12px;
  color: white;
  font-weight: 700;
}

.status-pill.connected {
  background: rgba(0, 184, 148, 0.34);
}

.status-pill.connecting {
  background: rgba(253, 203, 110, 0.30);
}

.section-card {
  background: @card_bg_color;
  border: 1px solid alpha(@borders, 0.72);
  border-radius: 18px;
  padding: 18px;
}

.device-list {
  background: transparent;
}

.device-list row {
  background: alpha(@view_bg_color, 0.72);
  border: 1px solid alpha(@borders, 0.62);
  border-radius: 14px;
  margin-top: 7px;
  padding: 4px;
}

.device-list row:selected {
  background: alpha(@accent_bg_color, 0.16);
  border-color: alpha(@accent_bg_color, 0.72);
}

.device-icon {
  background: alpha(@accent_bg_color, 0.13);
  color: @accent_color;
  border-radius: 12px;
  padding: 10px;
}

.option-card {
  background: alpha(@view_bg_color, 0.7);
  border: 1px solid alpha(@borders, 0.55);
  border-radius: 14px;
  padding: 14px;
}

.primary-action {
  min-height: 48px;
  border-radius: 14px;
  font-weight: 800;
}

.source-notice {
  background: alpha(#f9ca24, 0.12);
  border: 1px solid alpha(#f9ca24, 0.38);
  border-radius: 12px;
  padding: 12px;
}

.log-view {
  font-family: monospace;
  font-size: 0.9em;
  background: alpha(@view_bg_color, 0.65);
}
"""


@dataclass(frozen=True)
class Device:
    name: str
    address: str
    port: int
    model: str = "AirPlay receiver"

    @property
    def key(self) -> tuple[str, int]:
        return self.address, self.port


def discover_devices() -> list[Device]:
    completed = subprocess.run(
        [DOUBLETAKE, "-discover-json"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=12,
        check=False,
    )
    if completed.returncode != 0:
        message = completed.stderr.strip() or f"discovery exited with status {completed.returncode}"
        raise RuntimeError(message)
    records = json.loads(completed.stdout or "[]")
    found: dict[tuple[str, int], Device] = {}
    for record in records:
        device = Device(
            name=str(record.get("name") or "AirPlay receiver"),
            address=str(record["ip"]),
            port=int(record.get("port") or 7000),
            model=str(record.get("model") or "AirPlay receiver"),
        )
        found[device.key] = device
    return sorted(found.values(), key=lambda item: (item.name.casefold(), item.address))


def label(text: str, css_class: str | None = None, *, xalign: float = 0) -> Gtk.Label:
    widget = Gtk.Label(label=text, xalign=xalign)
    if css_class:
        widget.add_css_class(css_class)
    return widget


class AirPlayWindow(Adw.ApplicationWindow):
    def __init__(self, app: Adw.Application):
        super().__init__(application=app)
        self.set_title("AirPlay")
        self.set_default_size(860, 740)
        self.set_size_request(620, 560)

        self.devices: dict[tuple[str, int], Device] = {}
        self.selected_device: Device | None = None
        self.process: subprocess.Popen[bytes] | None = None
        self.reader_thread: threading.Thread | None = None
        self.prompt_visible = False
        self.stopping = False

        self._build_ui()
        self.connect("close-request", self._on_close_request)
        self.refresh_devices()

    def _build_ui(self) -> None:
        overlay = Adw.ToastOverlay()
        toolbar = Adw.ToolbarView()
        overlay.set_child(toolbar)
        self.set_content(overlay)
        self.toast_overlay = overlay

        header = Adw.HeaderBar()
        header.set_title_widget(label("AirPlay", "title-3", xalign=0.5))
        refresh = Gtk.Button(icon_name="view-refresh-symbolic", tooltip_text="Find AirPlay TVs")
        refresh.connect("clicked", lambda *_: self.refresh_devices())
        header.pack_end(refresh)
        self.refresh_button = refresh
        toolbar.add_top_bar(header)

        scroller = Gtk.ScrolledWindow(vexpand=True, hscrollbar_policy=Gtk.PolicyType.NEVER)
        toolbar.set_content(scroller)
        clamp = Adw.Clamp(maximum_size=850, tightening_threshold=720)
        scroller.set_child(clamp)

        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18)
        content.set_margin_top(18)
        content.set_margin_bottom(24)
        content.set_margin_start(18)
        content.set_margin_end(18)
        clamp.set_child(content)

        content.append(self._build_hero())
        content.append(self._build_devices())
        content.append(self._build_options())
        content.append(self._build_actions())
        content.append(self._build_log())

    def _build_hero(self) -> Gtk.Widget:
        hero = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=18)
        hero.add_css_class("airplay-hero")

        icon = Gtk.Image.new_from_icon_name("video-display-symbolic")
        icon.set_pixel_size(46)
        icon.add_css_class("hero-icon")
        icon.set_valign(Gtk.Align.CENTER)
        hero.append(icon)

        copy = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4, hexpand=True)
        copy.append(label("Your screen, on the big screen.", "title-1"))
        subtitle = label("Mirror this computer with sound to any AirPlay TV.", "caption")
        subtitle.set_wrap(True)
        copy.append(subtitle)
        hero.append(copy)

        self.status_label = label("Ready", xalign=0.5)
        self.status_box = Gtk.Box()
        self.status_box.add_css_class("status-pill")
        self.status_box.set_valign(Gtk.Align.CENTER)
        self.status_box.append(self.status_label)
        hero.append(self.status_box)
        return hero

    def _build_devices(self) -> Gtk.Widget:
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        card.add_css_class("section-card")

        heading = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        title_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2, hexpand=True)
        title_box.append(label("Choose a TV", "title-3"))
        title_box.append(label("AirPlay receivers found on this network", "caption"))
        heading.append(title_box)
        self.discovery_spinner = Gtk.Spinner(valign=Gtk.Align.CENTER)
        heading.append(self.discovery_spinner)
        card.append(heading)

        self.device_list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE)
        self.device_list.add_css_class("device-list")
        self.device_list.connect("row-selected", self._on_device_selected)
        placeholder = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        placeholder.set_margin_top(18)
        placeholder.set_margin_bottom(18)
        empty_icon = Gtk.Image.new_from_icon_name("network-wireless-offline-symbolic")
        empty_icon.set_pixel_size(30)
        placeholder.append(empty_icon)
        empty = label("No AirPlay TVs found", "dim-label", xalign=0.5)
        placeholder.append(empty)
        self.device_list.set_placeholder(placeholder)
        card.append(self.device_list)
        return card

    def _build_options(self) -> Gtk.Widget:
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=13)
        card.add_css_class("section-card")
        card.append(label("Mirroring options", "title-3"))

        source = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        source.add_css_class("option-card")
        source.append(label("Source", "heading"))
        buttons = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8, homogeneous=True)
        self.screen_mode = Gtk.ToggleButton(active=True)
        screen_content = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        screen_content.set_halign(Gtk.Align.CENTER)
        screen_content.append(Gtk.Image.new_from_icon_name("video-display-symbolic"))
        screen_content.append(label("Entire display"))
        self.screen_mode.set_child(screen_content)
        self.window_mode = Gtk.ToggleButton()
        window_content = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        window_content.set_halign(Gtk.Align.CENTER)
        window_content.append(Gtk.Image.new_from_icon_name("window-symbolic"))
        window_content.append(label("App window"))
        self.window_mode.set_child(window_content)
        self.window_mode.set_group(self.screen_mode)
        self.screen_mode.connect("toggled", self._on_mode_changed)
        buttons.append(self.screen_mode)
        buttons.append(self.window_mode)
        source.append(buttons)
        card.append(source)

        switches = Gtk.Grid(column_spacing=16, row_spacing=10)
        switches.add_css_class("option-card")

        switches.attach(label("Desktop audio", "heading"), 0, 0, 1, 1)
        switches.attach(label("Stream sound without changing the TV volume", "caption"), 0, 1, 1, 1)
        self.audio_switch = Gtk.Switch(active=True, halign=Gtk.Align.END, valign=Gtk.Align.CENTER)
        switches.attach(self.audio_switch, 1, 0, 1, 2)

        switches.attach(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL), 0, 2, 2, 1)
        switches.attach(label("Show pointer", "heading"), 0, 3, 1, 1)
        switches.attach(label("Include the mouse pointer in the picture", "caption"), 0, 4, 1, 1)
        self.cursor_switch = Gtk.Switch(active=True, halign=Gtk.Align.END, valign=Gtk.Align.CENTER)
        switches.attach(self.cursor_switch, 1, 3, 1, 2)

        switches.attach(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL), 0, 5, 2, 1)
        switches.attach(label("Frame rate", "heading"), 0, 6, 1, 1)
        switches.attach(label("30 FPS is smoother on most Wi-Fi networks", "caption"), 0, 7, 1, 1)
        self.fps_dropdown = Gtk.DropDown.new_from_strings(["24 FPS", "30 FPS", "60 FPS"])
        self.fps_dropdown.set_selected(1)
        self.fps_dropdown.set_halign(Gtk.Align.END)
        switches.attach(self.fps_dropdown, 1, 6, 1, 2)
        card.append(switches)

        notice = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        notice.add_css_class("source-notice")
        notice_icon = Gtk.Image.new_from_icon_name("dialog-information-symbolic")
        notice.append(notice_icon)
        self.source_notice = label(
            "When the system share picker opens, select the physical display you want to mirror. "
            "Display capture stays stable when apps enter fullscreen.",
            "caption",
        )
        self.source_notice.set_wrap(True)
        self.source_notice.set_hexpand(True)
        notice.append(self.source_notice)
        card.append(notice)
        return card

    def _build_actions(self) -> Gtk.Widget:
        area = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.action_button = Gtk.Button(label="Start mirroring", sensitive=False)
        self.action_button.add_css_class("suggested-action")
        self.action_button.add_css_class("primary-action")
        self.action_button.connect("clicked", self._on_action_clicked)
        area.append(self.action_button)
        self.endpoint_label = label("Choose a TV to continue", "caption", xalign=0.5)
        area.append(self.endpoint_label)
        return area

    def _build_log(self) -> Gtk.Widget:
        expander = Gtk.Expander(label="Connection details")
        expander.set_resize_toplevel(True)
        frame = Gtk.Frame()
        log_scroll = Gtk.ScrolledWindow(min_content_height=130)
        frame.set_child(log_scroll)
        self.log_buffer = Gtk.TextBuffer()
        self.log_view = Gtk.TextView(
            buffer=self.log_buffer,
            editable=False,
            cursor_visible=False,
            monospace=True,
            wrap_mode=Gtk.WrapMode.WORD_CHAR,
        )
        self.log_view.add_css_class("log-view")
        log_scroll.set_child(self.log_view)
        expander.set_child(frame)
        return expander

    def refresh_devices(self) -> None:
        if self.process is not None:
            return
        self.refresh_button.set_sensitive(False)
        self.discovery_spinner.start()
        self._append_log("Searching for AirPlay receivers…")

        def worker() -> None:
            try:
                devices = discover_devices()
                error = None
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
                devices = []
                error = str(exc)
            GLib.idle_add(self._finish_discovery, devices, error)

        threading.Thread(target=worker, name="airplay-discovery", daemon=True).start()

    def _finish_discovery(self, devices: list[Device], error: str | None) -> bool:
        self.refresh_button.set_sensitive(True)
        self.discovery_spinner.stop()
        previous_key = self.selected_device.key if self.selected_device else None

        while child := self.device_list.get_first_child():
            self.device_list.remove(child)

        self.devices = {device.key: device for device in devices}
        select_row = None
        for device in devices:
            row = self._device_row(device)
            self.device_list.append(row)
            if device.key == previous_key or (previous_key is None and len(devices) == 1):
                select_row = row
        if select_row:
            self.device_list.select_row(select_row)
        elif previous_key not in self.devices:
            self.selected_device = None
            self.action_button.set_sensitive(False)
            self.endpoint_label.set_text("Choose a TV to continue")

        if error:
            self._append_log(f"Discovery failed: {error}")
            self.toast_overlay.add_toast(Adw.Toast(title="Could not search the network"))
        elif devices:
            self._append_log(f"Found {len(devices)} AirPlay receiver{'s' if len(devices) != 1 else ''}.")
        else:
            self._append_log("No AirPlay receivers were found.")
        return GLib.SOURCE_REMOVE

    def _device_row(self, device: Device) -> Gtk.ListBoxRow:
        row = Gtk.ListBoxRow()
        row.device = device
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=13)
        box.set_margin_top(8)
        box.set_margin_bottom(8)
        box.set_margin_start(10)
        box.set_margin_end(10)
        icon = Gtk.Image.new_from_icon_name("video-display-symbolic")
        icon.set_pixel_size(26)
        icon.add_css_class("device-icon")
        box.append(icon)
        copy = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2, hexpand=True)
        copy.append(label(device.name, "heading"))
        copy.append(label(f"{device.model}  •  {device.address}:{device.port}", "caption"))
        box.append(copy)
        chevron = Gtk.Image.new_from_icon_name("go-next-symbolic")
        chevron.add_css_class("dim-label")
        box.append(chevron)
        row.set_child(box)
        return row

    def _on_device_selected(self, _list: Gtk.ListBox, row: Gtk.ListBoxRow | None) -> None:
        self.selected_device = getattr(row, "device", None) if row else None
        if self.selected_device:
            device = self.selected_device
            self.action_button.set_sensitive(self.process is None)
            self.endpoint_label.set_text(f"{device.name}  •  {device.address}:{device.port}")
        else:
            self.action_button.set_sensitive(False)

    def _on_mode_changed(self, button: Gtk.ToggleButton) -> None:
        if not button.get_active():
            return
        if self.screen_mode.get_active():
            self.source_notice.set_text(
                "When the system share picker opens, select the physical display you want to mirror. "
                "This keeps the picture stable when apps enter fullscreen."
            )
        else:
            self.source_notice.set_text(
                "Choose one app in the system share picker. Its stream may briefly renegotiate "
                "when that app changes size or enters fullscreen."
            )

    def _on_action_clicked(self, _button: Gtk.Button) -> None:
        if self.process is not None:
            self.stop_mirroring()
        else:
            self.start_mirroring()

    def start_mirroring(self) -> None:
        device = self.selected_device
        if device is None:
            return
        fps = (24, 30, 60)[self.fps_dropdown.get_selected()]
        mode = "monitor" if self.screen_mode.get_active() else "window"
        args = [
            DOUBLETAKE,
            "-target", device.address,
            "-port", str(device.port),
            "-capture-source", mode,
            "-fps", str(fps),
            "-hwaccel", "none",
            "-preserve-receiver-volume=true",
        ]
        if not self.audio_switch.get_active():
            args.append("-no-audio")
        if not self.cursor_switch.get_active():
            args.append("-no-cursor")

        self.log_buffer.set_text("")
        self._append_log(f"Connecting to {device.name} at {device.address}:{device.port}…")
        if mode == "monitor":
            self._append_log("In the system picker, choose the physical display you want to mirror.")
        self._set_status("Choose display", "connecting")
        self._set_running_ui(True)
        self.stopping = False
        self.prompt_visible = False
        try:
            self.process = subprocess.Popen(
                args,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                bufsize=0,
                start_new_session=True,
            )
        except OSError as exc:
            self.process = None
            self._append_log(f"Could not start mirroring: {exc}")
            self._set_status("Could not start", None)
            self._set_running_ui(False)
            self.toast_overlay.add_toast(Adw.Toast(title="Could not start AirPlay"))
            return

        proc = self.process
        self.reader_thread = threading.Thread(
            target=self._read_process,
            args=(proc,),
            name="airplay-output",
            daemon=True,
        )
        self.reader_thread.start()

    def stop_mirroring(self) -> None:
        proc = self.process
        if proc is None or self.stopping:
            return
        self.stopping = True
        self._set_status("Stopping…", "connecting")
        self.action_button.set_sensitive(False)
        try:
            proc.send_signal(signal.SIGINT)
        except ProcessLookupError:
            pass

        def force_stop() -> bool:
            if self.process is proc and proc.poll() is None:
                try:
                    proc.terminate()
                except ProcessLookupError:
                    pass
            return GLib.SOURCE_REMOVE

        GLib.timeout_add_seconds(4, force_stop)

    def _read_process(self, proc: subprocess.Popen[bytes]) -> None:
        decoder = codecs.getincrementaldecoder("utf-8")("replace")
        try:
            assert proc.stdout is not None
            while True:
                chunk = os.read(proc.stdout.fileno(), 1024)
                if not chunk:
                    break
                text = decoder.decode(chunk)
                if text:
                    GLib.idle_add(self._handle_output, proc, text)
            remainder = decoder.decode(b"", final=True)
            if remainder:
                GLib.idle_add(self._handle_output, proc, remainder)
        except OSError as exc:
            GLib.idle_add(self._append_log, f"Output reader stopped: {exc}")
        return_code = proc.wait()
        GLib.idle_add(self._process_exited, proc, return_code)

    def _handle_output(self, proc: subprocess.Popen[bytes], text: str) -> bool:
        if self.process is not proc:
            return GLib.SOURCE_REMOVE
        self._append_log(text.rstrip("\n"))
        lower = text.lower()
        if "connected to:" in lower:
            self._set_status("Preparing…", "connecting")
        if "mirror session ready" in lower or "screen capture started" in lower:
            self._set_status("Mirroring", "connected")
        if "streaming error:" in lower or "fatal" in lower:
            self._set_status("Connection error", None)
        prompt_markers = (
            "enter the pin shown on the receiver:",
            "enter the receiver's configured password:",
            "enter the receiver's configured password or pairing pin:",
            "enter the code shown on the receiver, or its configured password:",
        )
        if any(marker in lower for marker in prompt_markers) and not self.prompt_visible:
            self._show_credential_dialog(proc, "pin" in lower)
        return GLib.SOURCE_REMOVE

    def _show_credential_dialog(self, proc: subprocess.Popen[bytes], is_pin: bool) -> None:
        self.prompt_visible = True
        dialog = Gtk.Dialog(title="Enter AirPlay code", transient_for=self, modal=True)
        dialog.add_button("Cancel", Gtk.ResponseType.CANCEL)
        dialog.add_button("Connect", Gtk.ResponseType.OK)
        dialog.set_default_response(Gtk.ResponseType.OK)
        dialog.set_default_size(380, -1)
        box = dialog.get_content_area()
        box.set_spacing(10)
        box.set_margin_top(18)
        box.set_margin_bottom(18)
        box.set_margin_start(18)
        box.set_margin_end(18)
        title = "Enter the PIN shown on the TV" if is_pin else "Enter the TV password or pairing PIN"
        box.append(label(title, "title-3"))
        entry = Gtk.PasswordEntry(show_peek_icon=True, activates_default=True)
        entry.set_placeholder_text("AirPlay code")
        box.append(entry)

        def responded(_dialog: Gtk.Dialog, response: int) -> None:
            value = entry.get_text()
            self.prompt_visible = False
            if response == Gtk.ResponseType.OK and value and self.process is proc and proc.stdin:
                try:
                    proc.stdin.write((value + "\n").encode())
                    proc.stdin.flush()
                    self._append_log("AirPlay code submitted.")
                except (BrokenPipeError, OSError):
                    self._append_log("The connection closed before the code could be submitted.")
            else:
                self.stop_mirroring()
            _dialog.destroy()

        dialog.connect("response", responded)
        dialog.present()
        entry.grab_focus()

    def _process_exited(self, proc: subprocess.Popen[bytes], return_code: int) -> bool:
        if self.process is not proc:
            return GLib.SOURCE_REMOVE
        was_stopping = self.stopping
        self.process = None
        self.stopping = False
        self.reader_thread = None
        self._set_running_ui(False)
        if was_stopping or return_code in (0, -signal.SIGINT, -signal.SIGTERM):
            self._set_status("Ready", None)
            self._append_log("Mirroring stopped.")
        else:
            self._set_status("Connection ended", None)
            self._append_log(f"AirPlay exited with status {return_code}.")
            self.toast_overlay.add_toast(Adw.Toast(title="AirPlay connection ended"))
        return GLib.SOURCE_REMOVE

    def _set_running_ui(self, running: bool) -> None:
        self.action_button.set_label("Stop mirroring" if running else "Start mirroring")
        if running:
            self.action_button.remove_css_class("suggested-action")
            self.action_button.add_css_class("destructive-action")
            self.action_button.set_sensitive(True)
        else:
            self.action_button.remove_css_class("destructive-action")
            self.action_button.add_css_class("suggested-action")
            self.action_button.set_sensitive(self.selected_device is not None)
        self.device_list.set_sensitive(not running)
        self.screen_mode.set_sensitive(not running)
        self.window_mode.set_sensitive(not running)
        self.audio_switch.set_sensitive(not running)
        self.cursor_switch.set_sensitive(not running)
        self.fps_dropdown.set_sensitive(not running)
        self.refresh_button.set_sensitive(not running)

    def _set_status(self, text: str, state: str | None) -> None:
        self.status_label.set_text(text)
        self.status_box.remove_css_class("connected")
        self.status_box.remove_css_class("connecting")
        if state:
            self.status_box.add_css_class(state)

    def _append_log(self, text: str) -> bool:
        if not text:
            return GLib.SOURCE_REMOVE
        end = self.log_buffer.get_end_iter()
        prefix = "" if end.get_offset() == 0 else "\n"
        self.log_buffer.insert(end, prefix + text)
        lines = self.log_buffer.get_line_count()
        if lines > 300:
            start = self.log_buffer.get_start_iter()
            cutoff = self.log_buffer.get_iter_at_line(lines - 250)
            self.log_buffer.delete(start, cutoff)
        end = self.log_buffer.get_end_iter()
        self.log_view.scroll_to_iter(end, 0.0, False, 0.0, 1.0)
        return GLib.SOURCE_REMOVE

    def _on_close_request(self, _window: Gtk.Window) -> bool:
        proc = self.process
        if proc is not None and proc.poll() is None:
            try:
                proc.send_signal(signal.SIGINT)
            except ProcessLookupError:
                pass
        return False


class AirPlayApplication(Adw.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.DEFAULT_FLAGS)

    def do_startup(self) -> None:
        Adw.Application.do_startup(self)
        provider = Gtk.CssProvider()
        provider.load_from_data(CSS.encode())
        display = Gdk.Display.get_default()
        if display:
            Gtk.StyleContext.add_provider_for_display(
                display, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
            )

    def do_activate(self) -> None:
        window = self.get_active_window()
        if window is None:
            window = AirPlayWindow(self)
        window.present()


if __name__ == "__main__":
    raise SystemExit(AirPlayApplication().run(None))
