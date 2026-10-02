import Foundation

// MARK: - Amica Viewer Bridge

/// Runtime control over the Three.js viewer that lives inside `amica.bundle`.
///
/// The bundled Javascript never published a handle to its viewer instance, so
/// the app's existing `window.__viewer` / `window.__amicaPlayAnimation` calls
/// silently did nothing — the gesture feature was dead code.
///
/// Two one-line insertions were made in
/// `Resources/amica.bundle/_next/static/chunks/5322-96c4319453ac0e15.js` which now
/// publish `window.__viewer` (the VRM viewer) and `window.__amicaLoadAnimation`
/// (the `.vrma` loader). Everything below builds on those handles.
///
/// All snippets are defensive: if a handle is missing they report `false`
/// instead of throwing, so a future bundle update degrades instead of crashing.
enum AmicaViewerBridge {

    // MARK: - User defaults keys

    enum DefaultsKey {
        static let backgroundID = "amica_scene_background_id"
        static let subjectOffset = "amica_scene_subject_offset"
        static let zoomMax = "amica_scene_zoom_max"
    }

    static let defaultZoomMax: Double = 6.0
    static let defaultZoomMin: Double = 0.5

    // MARK: - Bootstrap

    /// Installed once at document start. Defines stable `window.__scowld*`
    /// helpers so the app never has to reach into minified internals directly.
    static let bootstrapScript = """
    (function() {
        if (window.__scowldBridgeInstalled) return;
        window.__scowldBridgeInstalled = true;

        function viewer() {
            var v = window.__viewer;
            return (v && v.model) ? v : null;
        }

        window.__scowldReady = function() { return viewer() !== null; };

        window.__scowldPlayGesture = function(name) {
            return new Promise(function(resolve) {
                try {
                    var v = viewer();
                    if (!v || !window.__amicaLoadAnimation || !name) { resolve(false); return; }
                    window.__amicaLoadAnimation('/animations/' + name + '.vrma')
                        .then(function(clip) {
                            if (!clip) { resolve(false); return; }
                            return v.model.playAnimation(clip, name + '.vrma');
                        })
                        .then(function() { resolve(true); })
                        .catch(function(e) {
                            console.error('[Scowld] gesture ' + name + ' failed: ' + e);
                            resolve(false);
                        });
                } catch (e) {
                    console.error('[Scowld] gesture threw: ' + e);
                    resolve(false);
                }
            });
        };

        window.__scowldSetExpression = function(name) {
            try {
                var v = viewer();
                if (!v || !name) return false;
                v.model.playEmotion(name);
                return true;
            } catch (e) {
                console.error('[Scowld] expression failed: ' + e);
                return false;
            }
        };

        window.__scowldResetCamera = function() {
            try {
                var v = window.__viewer;
                if (v && typeof v.resetCamera === 'function') { v.resetCamera(); return true; }
                return false;
            } catch (e) { return false; }
        };

        window.__scowldSetZoomLimits = function(minDistance, maxDistance) {
            try {
                var v = window.__viewer;
                if (!v || !v.cameraControls) return false;
                v.cameraControls.minDistance = minDistance;
                v.cameraControls.maxDistance = maxDistance;
                v.cameraControls.update();
                return true;
            } catch (e) { return false; }
        };

        window.__scowldSetSubjectOffset = function(fraction) {
            try {
                var v = window.__viewer;
                if (!v || !v.camera) return false;
                var cam = v.camera;
                var w = window.innerWidth;
                var h = window.innerHeight;
                if (!fraction) {
                    if (typeof cam.clearViewOffset === 'function') { cam.clearViewOffset(); }
                    return true;
                }
                if (typeof cam.setViewOffset !== 'function') return false;
                cam.setViewOffset(w, h, -fraction * w, 0, w, h);
                return true;
            } catch (e) { return false; }
        };

        window.__scowldSetBackground = function(imageURL, colour) {
            try {
                if (imageURL) {
                    document.body.style.backgroundImage = 'url("' + imageURL + '")';
                    document.body.style.backgroundColor = '';
                } else if (colour) {
                    document.body.style.backgroundImage = 'none';
                    document.body.style.backgroundColor = colour;
                } else {
                    document.body.style.backgroundImage = '';
                    document.body.style.backgroundColor = '';
                }
                return true;
            } catch (e) { return false; }
        };

        // Scene state pushed down from the app. Kept in one object so a refresh
        // is a single assignment followed by one apply call.
        window.__scowldScene = { background: null, offset: 0, zoomMax: 6 };

        window.__scowldApplyScene = function() {
            var scene = window.__scowldScene || {};
            if (window.__scowldSetBackground) {
                window.__scowldSetBackground(scene.background || null, null);
            }
            if (window.__scowldSetSubjectOffset) {
                window.__scowldSetSubjectOffset(scene.offset || 0);
            }
            if (window.__scowldSetZoomLimits) {
                window.__scowldSetZoomLimits(0.5, scene.zoomMax || 6);
            }
        };

        // The viewer is created asynchronously and the canvas is swapped while
        // the VRM loads, so re-apply whenever a canvas (re)appears.
        window.__scowldReapplyScene = function() {
            window.__scowldApplyScene();
        };
        try {
            var observer = new MutationObserver(function() {
                if (document.querySelector('canvas')) window.__scowldReapplyScene();
            });
            observer.observe(document.documentElement, { childList: true, subtree: true });
        } catch (e) {}
    })();
    """

    // MARK: - Runtime commands

    /// Plays a `.vrma` body animation by file name (without extension).
    static func playGestureScript(_ gestureID: String) -> String {
        "window.__scowldPlayGesture && window.__scowldPlayGesture('\(escaped(gestureID))')"
    }

    /// Applies a VRM preset facial expression.
    static func expressionScript(_ expression: String) -> String {
        "window.__scowldSetExpression && window.__scowldSetExpression('\(escaped(expression))')"
    }

    static let resetCameraScript = "window.__scowldResetCamera && window.__scowldResetCamera()"

    /// Pushes the current scene preferences into the page and applies them once.
    /// Safe to call repeatedly, e.g. while dragging a slider in Settings.
    static func applySceneScript(defaults: UserDefaults = .standard) -> String {
        let background = AmicaSceneSettings.background(defaults: defaults)
        let offset = AmicaSceneSettings.subjectOffset(defaults: defaults)
        let zoomMax = AmicaSceneSettings.zoomMax(defaults: defaults)
        let imageLiteral = background.map { "'\(escaped($0.imageURL))'" } ?? "null"

        return """
        (function() {
            window.__scowldScene = {
                background: \(imageLiteral),
                offset: \(format(offset)),
                zoomMax: \(format(zoomMax))
            };
            if (typeof window.__scowldApplyScene === 'function') {
                window.__scowldApplyScene();
            }
        })();
        """
    }

    /// Initial variant: applies immediately **and** keeps retrying briefly,
    /// because the web app builds its viewer asynchronously after page load.
    static func initialSceneScript(defaults: UserDefaults = .standard) -> String {
        """
        \(applySceneScript(defaults: defaults))
        (function() {
            var attempts = 0;
            var timer = setInterval(function() {
                attempts += 1;
                if (typeof window.__scowldApplyScene === 'function') window.__scowldApplyScene();
                if ((window.__scowldReady && window.__scowldReady()) || attempts > 40) {
                    clearInterval(timer);
                }
            }, 250);
        })();
        """
    }

    // MARK: - Helpers

    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}

// MARK: - Scene settings

/// UserDefaults-backed scene preferences, shared by Settings and the web view.
enum AmicaSceneSettings {
    static func backgroundID(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: AmicaViewerBridge.DefaultsKey.backgroundID) ?? ""
    }

    static func background(defaults: UserDefaults = .standard) -> AmicaBackground? {
        AmicaBackground.preset(id: backgroundID(defaults: defaults))
    }

    static func subjectOffset(defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: AmicaViewerBridge.DefaultsKey.subjectOffset) != nil else {
            return 0
        }
        return min(0.6, max(-0.6, defaults.double(forKey: AmicaViewerBridge.DefaultsKey.subjectOffset)))
    }

    static func zoomMax(defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: AmicaViewerBridge.DefaultsKey.zoomMax) != nil else {
            return AmicaViewerBridge.defaultZoomMax
        }
        return min(20, max(2, defaults.double(forKey: AmicaViewerBridge.DefaultsKey.zoomMax)))
    }

    static func setBackground(id: String, defaults: UserDefaults = .standard) {
        defaults.set(id, forKey: AmicaViewerBridge.DefaultsKey.backgroundID)
    }

    static func setSubjectOffset(_ value: Double, defaults: UserDefaults = .standard) {
        defaults.set(min(0.6, max(-0.6, value)), forKey: AmicaViewerBridge.DefaultsKey.subjectOffset)
    }

    static func setZoomMax(_ value: Double, defaults: UserDefaults = .standard) {
        defaults.set(min(20, max(2, value)), forKey: AmicaViewerBridge.DefaultsKey.zoomMax)
    }
}

// MARK: - Bundled backgrounds

/// The background images shipped inside `amica.bundle/bg/`.
struct AmicaBackground: Identifiable, Hashable {
    let id: String
    let title: String

    var imageURL: String { "/bg/\(id).jpg" }
    var thumbnailURL: String { "/bg/thumb-\(id).jpg" }

    static let presets: [AmicaBackground] = [
        AmicaBackground(id: "bg-room1", title: "Cozy Room"),
        AmicaBackground(id: "bg-room2", title: "Loft Room"),
        AmicaBackground(id: "bg-forest1", title: "Forest"),
        AmicaBackground(id: "bg-sunset1", title: "Sunset"),
        AmicaBackground(id: "bg-town1", title: "Town"),
        AmicaBackground(id: "bg-landscape1", title: "Landscape"),
        AmicaBackground(id: "bg-landscape2", title: "Meadow"),
        AmicaBackground(id: "bg-landscape3", title: "Mountains"),
        AmicaBackground(id: "bg-arbius1", title: "Arbius I"),
        AmicaBackground(id: "bg-arbius2", title: "Arbius II"),
    ]

    static func preset(id: String) -> AmicaBackground? {
        presets.first { $0.id == id }
    }
}

// MARK: - Bundled gestures

/// The `.vrma` body animations shipped inside `amica.bundle/animations/`.
struct AmicaGesture: Identifiable, Hashable {
    let id: String
    let title: String
    let systemImage: String

    static let presets: [AmicaGesture] = [
        AmicaGesture(id: "greeting", title: "Greet", systemImage: "hand.wave.fill"),
        AmicaGesture(id: "dance", title: "Dance", systemImage: "music.note"),
        AmicaGesture(id: "peaceSign", title: "Peace sign", systemImage: "hand.raised.fill"),
        AmicaGesture(id: "modelPose", title: "Pose", systemImage: "figure.stand"),
        AmicaGesture(id: "spin", title: "Spin", systemImage: "arrow.triangle.2.circlepath"),
        AmicaGesture(id: "squat", title: "Squat", systemImage: "figure.strengthtraining.traditional"),
        AmicaGesture(id: "shoot", title: "Shoot", systemImage: "camera.fill"),
        AmicaGesture(id: "showFullBody", title: "Full body", systemImage: "figure.arms.open"),
    ]
}

// MARK: - Facial expressions

/// VRM preset expressions understood by the bundled emoter.
enum AmicaExpression: String, CaseIterable, Identifiable {
    case happy
    case relaxed
    case surprised
    case sad
    case angry
    case neutral

    var id: String { rawValue }

    var title: String {
        switch self {
        case .happy: "Happy"
        case .relaxed: "Relaxed"
        case .surprised: "Surprised"
        case .sad: "Sad"
        case .angry: "Angry"
        case .neutral: "Neutral"
        }
    }

    var systemImage: String {
        switch self {
        case .happy: "face.smiling.inverse"
        case .relaxed: "face.smiling"
        case .surprised: "exclamationmark.circle"
        case .sad: "cloud.rain"
        case .angry: "flame"
        case .neutral: "circle.dashed"
        }
    }
}
