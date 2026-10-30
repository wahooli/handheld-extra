import { ButtonItem, PanelSection, PanelSectionRow, Router, ToggleField, staticClasses } from "@decky/ui";
import { callable, definePlugin } from "@decky/api";
import { useEffect, useState } from "react";
import { FaGamepad } from "react-icons/fa";

type Choice = { current: string; options: [string, string][] };
type ModesReply = { ok: boolean; error?: string; touch?: Choice | null; dpad?: Choice | null; per_game?: boolean };
type WriteReply = { ok: boolean; error?: string };

const getModes = callable<[appid: string], ModesReply>("get_modes");
const setMode = callable<[kind: string, mode: string], WriteReply>("set_mode");
const setPerGame = callable<[appid: string, enabled: boolean], WriteReply>("set_per_game");
const gameStarted = callable<[appid: string], WriteReply>("game_started");
const gameStopped = callable<[appid: string], WriteReply>("game_stopped");

const SECTIONS: { kind: "touch" | "dpad"; title: string }[] = [
  { kind: "touch", title: "Touch areas" },
  { kind: "dpad", title: "D-pad" },
];

const note = (text: string, color?: string) => (
  <PanelSectionRow>
    <div style={{ fontSize: "0.8em", color }}>{text}</div>
  </PanelSectionRow>
);

function Content() {
  const app = Router.MainRunningApp;
  const game = app ? { appid: String(app.appid), name: app.display_name } : null;
  const [modes, setModes] = useState<ModesReply | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const refresh = async () => setModes(await getModes(game?.appid ?? ""));
  useEffect(() => {
    void refresh();
  }, []);

  const run = async (write: () => Promise<WriteReply>, fallback: string) => {
    setBusy(true);
    try {
      const reply = await write();
      setError(reply.ok ? null : reply.error || fallback);
      await refresh();
    } finally {
      setBusy(false);
    }
  };

  if (!modes) return null;
  if (!modes.ok) return <PanelSection>{note(modes.error || "handheld-settings failed", "#ff6b6b")}</PanelSection>;
  const sections = SECTIONS.filter((s) => modes[s.kind]);
  if (sections.length === 0) return <PanelSection>{note("Not an AYANEO Pocket VERT.")}</PanelSection>;

  // One full-width button per mode rather than a dropdown: on the VERT's narrow
  // screen a dropdown's popup opens off the right edge.
  return (
    <>
      {game && (
        <PanelSection title="Profile">
          <PanelSectionRow>
            <ToggleField
              label="Per-game settings"
              description={modes.per_game ? `For ${game.name} only` : "Off: the default applies"}
              checked={!!modes.per_game}
              disabled={busy}
              onChange={(on) => void run(() => setPerGame(game.appid, on), "could not change the profile")}
            />
          </PanelSectionRow>
        </PanelSection>
      )}
      {sections.map(({ kind, title }) => {
        const choice = modes[kind]!;
        return (
          <PanelSection key={kind} title={modes.per_game ? `${title} (${game!.name})` : `${title} (default)`}>
            {choice.options.map(([name, label]) => (
              <PanelSectionRow key={name}>
                <ButtonItem
                  layout="below"
                  disabled={busy}
                  onClick={() => void run(() => setMode(kind, name), "could not change the mode")}
                >
                  {name === choice.current ? `✓ ${label}` : label}
                </ButtonItem>
              </PanelSectionRow>
            ))}
          </PanelSection>
        );
      })}
      {error && <PanelSection>{note(error, "#ff6b6b")}</PanelSection>}
    </>
  );
}

export default definePlugin(() => {
  // Apply a game's profile when it starts and the default when it exits, also
  // while the panel is closed. A game already running at load gets its own now.
  const running = Router.MainRunningApp;
  if (running) void gameStarted(String(running.appid));
  const lifetime = SteamClient.GameSessions.RegisterForAppLifetimeNotifications((n) => {
    const appid = String(n.unAppID);
    void (n.bRunning ? gameStarted(appid) : gameStopped(appid));
  });

  return {
    name: "Pocket VERT Controls",
    titleView: <div className={staticClasses.Title}>Pocket VERT Controls</div>,
    content: <Content />,
    icon: <FaGamepad />,
    onDismount() {
      lifetime.unregister();
    },
  };
});
