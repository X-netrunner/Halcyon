use halcyon_music_core::models::Track;
use halcyon_music_core::protocol::{self, EventBody};
use halcyon_music_core::state::PlayerState;
use halcyon_musicd::cache::Cache;
use halcyon_musicd::daemon::Player;
use halcyon_musicd::mpris::{
    announce_changes, start_mpris_server, MPRIS_BUS_NAME, MPRIS_OBJECT_PATH,
};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{broadcast, watch};
use zbus::export::futures_util::StreamExt;

fn track() -> Track {
    Track {
        id: "t1".to_string(),
        title: "Title".to_string(),
        artist: "Artist".to_string(),
        artists: vec!["Artist".to_string()],
        album: "Album".to_string(),
        album_id: None,
        duration_ms: 200_000,
        art_url: None,
        uri: "spotify:track:t1".to_string(),
    }
}

async fn state_event(player: &Player) -> protocol::Event {
    protocol::event(EventBody::State {
        state: player.snapshot().await,
    })
}

#[tokio::test(flavor = "multi_thread")]
async fn seeks_and_app_side_changes_are_signalled() {
    if std::env::var("HALCYON_PRIVATE_BUS").is_err() {
        eprintln!("skipped: run under dbus-run-session with HALCYON_PRIVATE_BUS=1 (never on the real session bus)");
        return;
    }
    let dir = tempfile::tempdir().expect("tempdir");
    let cache = Cache::open(
        &dir.path().join("c.db"),
        &dir.path().join("img"),
        1024 * 1024,
    )
    .expect("cache");
    let (dirty_tx, _dirty_rx) = watch::channel(false);
    let player = Arc::new(Player::new(PlayerState::default(), dirty_tx));
    player.mutate(|s| s.play_track(track())).await;
    let (events_tx, _keep) = broadcast::channel(64);

    let server = start_mpris_server(player.clone(), cache, events_tx.clone())
        .await
        .expect("mpris server");
    tokio::spawn(announce_changes(server.clone(), events_tx.subscribe()));

    let client = zbus::Connection::session().await.expect("client");
    let mpris = zbus::Proxy::new(
        &client,
        MPRIS_BUS_NAME,
        MPRIS_OBJECT_PATH,
        "org.mpris.MediaPlayer2.Player",
    )
    .await
    .expect("player proxy");
    let props = zbus::fdo::PropertiesProxy::builder(&client)
        .destination(MPRIS_BUS_NAME)
        .expect("destination")
        .path(MPRIS_OBJECT_PATH)
        .expect("path")
        .build()
        .await
        .expect("properties proxy");

    let mut seeked = mpris.receive_signal("Seeked").await.expect("seeked stream");
    let _: () = mpris.call("Seek", &(5_000_000i64)).await.expect("seek");
    let msg = tokio::time::timeout(Duration::from_secs(3), seeked.next())
        .await
        .expect("Seeked within 3 s")
        .expect("a Seeked message");
    let position: i64 = msg.body().deserialize().expect("position");
    assert_eq!(position, 5_000_000);

    let can_quit: bool = mpris_root_property(&client, "CanQuit").await;
    assert!(
        !can_quit,
        "the daemon is a service: CanQuit must not promise a quit it cannot do"
    );

    events_tx.send(state_event(&player).await).expect("prime");
    tokio::time::sleep(Duration::from_millis(200)).await;
    let mut changed = props
        .receive_properties_changed()
        .await
        .expect("changes stream");
    player.mutate(|s| s.volume = 30).await;
    events_tx
        .send(state_event(&player).await)
        .expect("volume event");
    let sig = tokio::time::timeout(Duration::from_secs(3), changed.next())
        .await
        .expect("PropertiesChanged within 3 s")
        .expect("a PropertiesChanged message");
    let args = sig.args().expect("args");
    assert!(
        args.changed_properties().contains_key("Volume"),
        "an app-side volume change is announced"
    );
}

async fn mpris_root_property(client: &zbus::Connection, name: &str) -> bool {
    let root = zbus::Proxy::new(
        client,
        MPRIS_BUS_NAME,
        MPRIS_OBJECT_PATH,
        "org.mpris.MediaPlayer2",
    )
    .await
    .expect("root proxy");
    root.get_property(name).await.expect("property")
}
