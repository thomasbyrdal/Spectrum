import XCTest
@testable import Spectrum

final class NowPlayingControllerTests: XCTestCase {
    func testSupportsMusicAndSpotifyBundleIDs() {
        XCTAssertTrue(NowPlayingController.supports(bundleID: "com.apple.Music"))
        XCTAssertTrue(NowPlayingController.supports(bundleID: "com.apple.iTunes"))
        XCTAssertTrue(NowPlayingController.supports(bundleID: "com.spotify.client"))
    }

    func testDoesNotSupportOtherBundleIDs() {
        XCTAssertFalse(NowPlayingController.supports(bundleID: nil))
        XCTAssertFalse(NowPlayingController.supports(bundleID: ""))
        XCTAssertFalse(NowPlayingController.supports(bundleID: "com.apple.Safari"))
        XCTAssertFalse(NowPlayingController.supports(bundleID: "com.apple.finder"))
        XCTAssertFalse(NowPlayingController.supports(bundleID: "tv.plex.desktop"))
    }

    func testSupportsApplicationSourceOnlyForMusicAndSpotify() {
        XCTAssertTrue(NowPlayingController.supports(.application(process(bundleID: "com.apple.Music"))))
        XCTAssertTrue(NowPlayingController.supports(.application(process(bundleID: "com.spotify.client"))))
        XCTAssertFalse(NowPlayingController.supports(.application(process(bundleID: "com.apple.Safari"))))
        XCTAssertFalse(NowPlayingController.supports(.systemAudio))
        XCTAssertFalse(NowPlayingController.supports(.testSignal(.sine1k)))
        XCTAssertFalse(NowPlayingController.supports(.physical(AudioDevice.testSignal())))
    }

    func testTrackDisplayIncludesArtistWhenPresent() {
        XCTAssertEqual(
            NowPlayingController.trackDisplay(songTitle: "Nightcall", artist: "Kavinsky"),
            "Nightcall by Kavinsky"
        )
        XCTAssertEqual(
            NowPlayingController.trackDisplay(songTitle: "Helplessness Blues", artist: ""),
            "Helplessness Blues"
        )
        XCTAssertEqual(NowPlayingController.trackDisplay(songTitle: "", artist: "Kavinsky"), "")
    }

    func testWindowTitleIncludesSourceAndSong() {
        XCTAssertEqual(
            NowPlayingController.windowTitle(sourceName: "Spotify", trackDisplay: "Nightcall by Kavinsky", isAvailable: true),
            "Spectrum - Spotify playing Nightcall by Kavinsky"
        )
        XCTAssertEqual(
            NowPlayingController.windowTitle(sourceName: "Apple Music", trackDisplay: "Helplessness Blues by Fleet Foxes", isAvailable: true),
            "Spectrum - Apple Music playing Helplessness Blues by Fleet Foxes"
        )
    }

    func testWindowTitleFallsBackWhenSongIsMissing() {
        XCTAssertEqual(
            NowPlayingController.windowTitle(sourceName: "Spotify", trackDisplay: "", isAvailable: true),
            "Spectrum - Spotify"
        )
        XCTAssertEqual(
            NowPlayingController.windowTitle(sourceName: "Apple Music", trackDisplay: "  ", isAvailable: true),
            "Spectrum - Apple Music"
        )
        XCTAssertEqual(
            NowPlayingController.windowTitle(sourceName: "Spotify", trackDisplay: "Nightcall by Kavinsky", isAvailable: false),
            "Spectrum"
        )
    }

    private func process(bundleID: String) -> AudioProcess {
        AudioProcess(
            objectID: 1,
            pid: 1,
            bundleID: bundleID,
            name: "Test",
            isRunningOutput: true
        )
    }
}
