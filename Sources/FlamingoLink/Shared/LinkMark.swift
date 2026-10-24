// Shared by Capybara and Flamingo. Capybara's Sources/CapybaraLink is the original; Flamingo's
// Sources/FlamingoLink/Shared is a copy (scripts/sync-link.sh). Change it here, then sync.

// The link animation: Capybara and Flamingo connecting over the home network, drawn frame by
// frame in plain CoreGraphics. While they connect the flamingo flies over and lands on the
// capybara's back; the link counts as connected on the frame its foot touches down.
//
// Each app animates its own Dock icon from its own icon. `alone(.capybara)` is exactly
// scripts/make-icon.swift and `alone(.flamingo)` exactly Flamingo's Resources/Assets/make-icon.swift;
// every other frame is a pose of a small rig (camera, plate, capybara, flamingo) eased between
// keyframes. White animals, coral plates; the plate is the only gradient.
//
// Geometry is built once. A frame only computes a pose, then transforms and fills.

import Foundation
import CoreGraphics

public enum LinkMarkSide: String, Sendable { case capybara, flamingo }

public enum LinkScene: Equatable, Sendable {
    case alone(LinkMarkSide)                                        // exactly that app's own icon
    case approach(LinkMarkSide, t: Double)                          // t 0...1; t=1 equals hover(phase: 0)
    case hover(phase: Double)                                       // loops seamlessly every 1.0 of phase; identical on both sides
    case landing(t: Double, fromPhase: Double)                      // t 0...1, starts exactly at hover(fromPhase) for any fromPhase, feet touch at t == LinkMark.touchdown, t=1 equals together
    case together                                                   // the connected icon, still
    case departing(LinkMarkSide, t: Double, fromPhase: Double?)     // nil: starts at together; else starts at hover(fromPhase). t=1 equals alone(side)
}

public enum LinkMark {
    public static let approachDuration: Double = 1.1
    public static let hoverPeriod: Double = 0.6
    public static let landingDuration: Double = 1.0
    public static let touchdown: Double = 0.6
    public static let departDuration: Double = 1.1

    /// The full app icon for `scene` (plate with shadow + animals), filling `rect` exactly like the
    /// app icons do (macOS 824/1024 plate grid). CoreGraphics y-up coordinates.
    public static func drawIcon(_ scene: LinkScene, in ctx: CGContext, rect: CGRect) {
        Painter.icon(Rig(scene), ctx, rect)
    }

    /// The animals only, no plate, filled with `color` (for a small mark inside a window).
    /// `rect` stands for the plate: the animals sit in it as they sit on the icon's plate.
    public static func drawMark(_ scene: LinkScene, in ctx: CGContext, rect: CGRect, color: CGColor) {
        Painter.mark(Rig(scene), ctx, rect, color)
    }

    /// A square sRGB premultiplied image of drawIcon.
    public static func icon(_ scene: LinkScene, pixels: Int) -> CGImage? {
        guard pixels > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        drawIcon(scene, in: ctx, rect: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        return ctx.makeImage()
    }
}

extension LinkMark {
    // MARK: - The world

    /// The `together` composition, in units of a 1024 icon canvas, y up. The camera maps it onto the
    /// canvas; at zoom 1 world and canvas coincide.
    enum World {
        /// Capybara box units (make-icon.swift's 100×100) to world, and the flamingo's.
        static let capyScale: CGFloat = 5.0
        static let birdScale: CGFloat = 3.5
        /// The capybara's box origin when they stand together: the pair centred, a touch high.
        static let capyOrigin = CGPoint(x: 262, y: 676)
        /// Where the flamingo's foot stands: on the flat of the back, a little behind the middle.
        static let perch = CGPoint(x: capyOrigin.x + 40 * capyScale, y: capyOrigin.y - 42 * capyScale)
        /// The flamingo's body centre (box 48, 60) standing on the perch: foot centre on the back line.
        static let restAt = CGPoint(x: perch.x, y: perch.y + 35 * birdScale)
        /// The same, at the instant the foot's round tip first touches.
        static let contactAt = CGPoint(x: perch.x, y: restAt.y + 1.3 * birdScale)
        /// Hovering: above the perch and a touch behind, so it lands moving forward.
        static let hoverAt = CGPoint(x: perch.x - 10, y: restAt.y + 50)
        /// High enough for the capybara's ear to pass under the dangling feet.
        static let clearAt = CGPoint(x: hoverAt.x, y: restAt.y + 92)
        /// The flamingo standing on the ground, under where it hovers (Flamingo's own icon).
        static let groundAt = CGPoint(x: hoverAt.x, y: capyOrigin.y - 84 * capyScale + 36.3 * birdScale)

        /// Capybara's icon: make-icon.swift's placement on a 1024 canvas.
        static let capyIcon: (scale: CGFloat, origin: CGPoint) = {
            let box: CGFloat = 824 * 0.76
            return (box / 100, CGPoint(x: 512 - box / 2, y: 512 + box / 2 + box * 0.045))
        }()

        /// Flamingo's icon: FlamingoMarkPath fitted into make-icon.swift's mark rect.
        static let birdIcon: (scale: CGFloat, origin: CGPoint) = {
            let bb = Shapes.birdBounds
            let s = min(824 / bb.width, 600 / bb.height)
            return (s, CGPoint(x: 512 - bb.midX * s, y: 528 + bb.midY * s))
        }()

        /// Each app's own framing of the world: zoomed in on its animal.
        static func ownView(_ side: LinkMarkSide) -> (zoom: CGFloat, focus: CGPoint, seen: CGPoint) {
            switch side {
            case .capybara:
                let focus = CGPoint(x: capyOrigin.x + 50 * capyScale, y: capyOrigin.y - 54.5 * capyScale)
                let seen = CGPoint(x: capyIcon.origin.x + 50 * capyIcon.scale, y: capyIcon.origin.y - 54.5 * capyIcon.scale)
                return (capyIcon.scale / capyScale, focus, seen)
            case .flamingo:
                let seen = CGPoint(x: birdIcon.origin.x + 48 * birdIcon.scale, y: birdIcon.origin.y - 60 * birdIcon.scale)
                return (birdIcon.scale / birdScale, groundAt, seen)
            }
        }
    }

    // MARK: - The rig

    /// One frame: where the camera looks, which plate, and how each animal stands.
    struct Rig {
        var camera: Camera
        var plate: Plate
        var capy: Capy
        var bird: Bird

        init(camera: Camera, plate: Plate, capy: Capy, bird: Bird) {
            self.camera = camera; self.plate = plate; self.capy = capy; self.bird = bird
        }

        init(_ scene: LinkScene) { self = Timeline.rig(scene) }
    }

    struct Camera {
        var zoom: CGFloat = 1
        var shift = CGVector.zero

        static let world = Camera()

        /// `e` 0 is `side`'s own framing, 1 the shared world. Zooms geometrically while the focus
        /// travels straight, so the move reads as one camera. `tracking` keeps a moving subject
        /// as the focus (it must be at the framing's own focus when `e` is 0).
        init(_ side: LinkMarkSide, _ e: CGFloat, tracking: CGPoint? = nil) {
            let v = World.ownView(side)
            let focus = tracking ?? v.focus
            zoom = pow(v.zoom, 1 - e)
            let c = mix(v.seen, focus, e)
            shift = CGVector(dx: c.x - zoom * focus.x, dy: c.y - zoom * focus.y)
        }

        init() {}

        var transform: CGAffineTransform { CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom, tx: shift.dx, ty: shift.dy) }
    }

    /// `shared` 0 is `side`'s own plate, 1 the shared one.
    struct Plate {
        var side: LinkMarkSide
        var shared: CGFloat
    }

    /// The capybara, in its make-icon.swift box (y down).
    struct Capy {
        var origin = World.capyOrigin
        var front: CGFloat = 0, back: CGFloat = 0           // leg swing about the hip, radians, + forward
        var frontLift: CGFloat = 0, backLift: CGFloat = 0   // leg drawn up into the body, box units
        var drop: CGFloat = 0                               // whole animal lowered while the legs splay
        var squash: CGFloat = 0                             // body squashed about its belly line
        var ear: CGFloat = 0                                // ear flicked back, radians

        var isRest: Bool { front == 0 && back == 0 && frontLift == 0 && backLift == 0 && squash == 0 && ear == 0 }

        /// The squashed body maps a box point here (pivot: belly line, middle).
        func squashed(_ p: CGPoint) -> CGPoint {
            CGPoint(x: 50 + (p.x - 50) * (1 + 0.4 * squash), y: 76 + (p.y - 76) * (1 - squash))
        }
    }

    /// One flamingo leg: hip, knee, foot. Angles from straight down, + forward.
    struct Leg: Equatable {
        var thigh: CGFloat
        var shin: CGFloat

        static let standing = Leg(thigh: 0, shin: 0)
        static let folded = Leg(thigh: atan2(7, 10), shin: atan2(-11, 4))
    }

    /// The flamingo, in FlamingoMarkPath's box (y down).
    struct Bird {
        var at: CGPoint                         // world position of the body centre, box (48, 60)
        var pitch: CGFloat = 0                  // radians, + nose up
        var open: CGFloat = 0                   // wing spread: 0 folded into the body … 1
        var arm: CGFloat = Bird.fold            // wing elevation at the shoulder, radians
        var hand: CGFloat = Bird.fold           // and past the wrist; lags the arm
        var flex: CGFloat = 0                   // hand tucked in on the upstroke, 0…1
        var head = CGVector.zero                // head and beak moved, box units; the neck follows
        var standing = Leg.standing
        var folded = Leg.folded

        static let fold: CGFloat = 0.15
        static let pivot = CGPoint(x: 48, y: 60)

        var isRest: Bool { open == 0 && head == .zero && standing == .standing && folded == .folded }

        /// Box to world.
        var transform: CGAffineTransform {
            CGAffineTransform(translationX: at.x, y: at.y).rotated(by: pitch)
                .scaledBy(x: World.birdScale, y: -World.birdScale).translatedBy(x: -Bird.pivot.x, y: -Bird.pivot.y)
        }

        /// World offset from `at` to the standing foot's centre.
        var footOffset: CGVector {
            let f = Shapes.joints(hip: Shapes.standingHip, standing, Shapes.standingLengths).foot
            let v = CGPoint(x: (f.x - Bird.pivot.x) * World.birdScale, y: -(f.y - Bird.pivot.y) * World.birdScale)
            let c = cos(pitch), s = sin(pitch)
            return CGVector(dx: v.x * c - v.y * s, dy: v.x * s + v.y * c)
        }
    }
}

// MARK: - Scenes

extension LinkMark {
    /// Every scene as a rig. Boundaries meet exactly: each blend weight is exactly 0 or 1 there.
    enum Timeline {
        static func rig(_ scene: LinkScene) -> Rig {
            switch scene {
            case .alone(let side): return approach(side, 0)
            case .approach(let side, let t): return approach(side, unit(t))
            case .hover(let p): return hover(CGFloat(p.isFinite ? p : 0))
            case .landing(let t, let p): return landing(unit(t), CGFloat(p.isFinite ? p : 0))
            case .together: return together
            case .departing(let side, let t, let p): return departing(side, unit(t), p.map { CGFloat($0.isFinite ? $0 : 0) })
            }
        }

        static let together = Rig(camera: .world, plate: Plate(side: .flamingo, shared: 1), capy: Capy(), bird: Bird(at: World.restAt))

        static func hover(_ p: CGFloat) -> Rig {
            Rig(camera: .world, plate: Plate(side: .flamingo, shared: 1), capy: Capy(), bird: Flight.hover(p))
        }

        // Wing-beat phase runs at the hover rate in every scene, so nothing changes speed at a seam.
        static var beatsPerSecond: CGFloat { CGFloat(1 / LinkMark.hoverPeriod) }

        static func approach(_ side: LinkMarkSide, _ t: CGFloat) -> Rig {
            let n = CGFloat(LinkMark.approachDuration) * beatsPerSecond
            switch side {
            case .capybara:
                // Drops in from the top right, nose up and legs forward, braking into the hover.
                let p = -(1 - t) * n
                let h = Flight.hover(p)
                var b = h
                let s = Curve(0.18, 0.55, 0.32, 1)(t)
                let o = World.hoverAt
                let path = bezier(CGPoint(x: o.x + 400, y: o.y + 330), CGPoint(x: o.x + 260, y: o.y + 190),
                                  CGPoint(x: o.x + 60, y: o.y + 60), o, s)
                let w = smoother(ramp(t, 0.45, 1))
                b.at = mix(path, h.at, w)
                b.pitch = mix(0.2, h.pitch, w)
                b.standing = mix(Leg(thigh: 0.3, shin: 0.1), h.standing, w)
                b.folded = mix(Leg(thigh: 0.15, shin: -0.25), h.folded, w)
                b.head = mix(CGVector(dx: -1, dy: 0.5), h.head, w)
                let e = Curve(0.45, 0, 0.25, 1)(ramp(t, 0, 0.85))
                return Rig(camera: Camera(.capybara, e), plate: Plate(side: .capybara, shared: smooth(ramp(t, 0.1, 0.9))),
                           capy: Capy(), bird: b)
            case .flamingo:
                // Lifts off its spot (first stroke from mid-upstroke) while the camera pulls back and
                // the capybara walks in underneath.
                let c = fract(-n - 0.72)
                let p = -(1 - t) * n - c * (1 - t) * (1 - t)
                let h = Flight.hover(p)
                var b = Bird(at: World.groundAt)
                let o = smooth(ramp(t, 0, 0.22))
                b.open = o
                b.arm = mix(Bird.fold, h.arm, o)
                b.hand = mix(Bird.fold, h.hand, o)
                b.flex = h.flex * o
                // Up past the hover so the capybara's head passes under the feet, then down into it.
                let rise = Curve(0.4, 0, 0.3, 1)(ramp(t, 0.06, 0.5))
                let settle = Curve(0.4, 0, 0.3, 1)(ramp(t, 0.55, 1))
                let up = mix(mix(World.groundAt, World.clearAt, rise), World.hoverAt, settle)
                let bob = (h.at.y - World.hoverAt.y) * smoother(ramp(t, 0.4, 1))
                b.at = mix(CGPoint(x: up.x, y: up.y + bob), h.at, smoother(ramp(t, 0.92, 1)))
                b.standing = mix(.standing, h.standing, smooth(ramp(t, 0.18, 0.6)))
                b.folded = mix(.folded, h.folded, smooth(ramp(t, 0.05, 0.45)))
                b.head = mix(.zero, h.head, smooth(ramp(t, 0, 0.8)))
                b.pitch = mix(0, h.pitch, smooth(ramp(t, 0.1, 0.8)))
                let u = Curve(0.25, 0.45, 0.35, 1)(ramp(t, 0.18, 0.97))
                let capy = Gait.walking(-Gait.walkIn * (1 - u), env: 1 - smooth(ramp(u, 0.82, 1)))
                let e = Curve(0.4, 0, 0.25, 1)(ramp(t, 0, 0.8))
                return Rig(camera: Camera(.flamingo, e, tracking: b.at), plate: Plate(side: .flamingo, shared: smooth(ramp(t, 0.1, 0.9))),
                           capy: capy, bird: b)
            }
        }

        static func landing(_ t: CGFloat, _ p0: CGFloat) -> Rig {
            let duration = CGFloat(LinkMark.landingDuration), td = CGFloat(LinkMark.touchdown)
            let h = Flight.hover(p0 + t * duration * beatsPerSecond)
            var b = h
            var capy = Capy()

            // Wings: beats ease into a raised brake, held through touchdown, then fold away.
            let flare = smooth(ramp(t, 0.22, td))
            let fold = Curve(0.4, 0, 0.2, 1)(ramp(t, td + 0.03, td + 0.32))
            b.arm = mix(mix(h.arm, Flight.flareArm, flare), Bird.fold, fold)
            b.hand = mix(mix(h.hand, Flight.flareHand, flare), Bird.fold, fold)
            b.flex = h.flex * (1 - flare)
            b.open = 1 - fold

            // Legs: the standing leg reaches straight down; the other tucks into the "4" once down.
            let reach = smooth(ramp(t, 0.15, td - 0.06))
            let tuck = Curve(0.4, 0, 0.2, 1)(ramp(t, td + 0.05, td + 0.34))
            b.standing = mix(h.standing, .standing, reach)
            b.folded = mix(mix(h.folded, Flight.calmDangle, reach), .folded, tuck)
            b.head = mix(h.head, .zero, Curve(0.3, 0, 0.2, 1)(ramp(t, 0.3, 1)))
            b.pitch = mix(h.pitch, 0, smooth(ramp(t, 0.2, td)))

            if t <= td {
                // Down onto the back, still moving a little when the foot arrives.
                b.at = mix(h.at, World.contactAt, Curve(0.42, 0, 0.72, 0.6)(t / td))
            } else {
                // Down: the capybara gives under the weight and its ear flicks; the knee gives a
                // little; both settle. The foot stays planted on the back.
                let tau = (t - td) * duration
                let win = 1 - smoother(ramp(t, 0.82, 1))
                // The back starts down at about the speed the foot arrives, so the bird decelerates
                // into it rather than dropping through.
                capy.squash = 0.028 * tap(tau, hz: 1.8, damping: 0.72) * win
                capy.ear = 0.45 * tap(tau - 0.04, hz: 4.2, damping: 0.6) * win
                let bend = 0.18 * tap(tau - 0.03, hz: 2.2, damping: 0.8) * win
                b.standing = Leg(thigh: bend, shin: -bend)
                let sink = smooth(ramp(t, td, td + 0.25))
                b.at = planted(capy, sink: sink, b)
                b.at = mix(b.at, World.restAt, smoother(ramp(t, 0.9, 1)))
            }
            return Rig(camera: .world, plate: Plate(side: .flamingo, shared: 1), capy: capy, bird: b)
        }

        /// Body centre for a flamingo whose standing foot is on the perch of a (squashed) capybara;
        /// `sink` 0 is the round tip just touching, 1 the foot settled into the coat.
        static func planted(_ capy: Capy, sink: CGFloat, _ b: Bird) -> CGPoint {
            let p = capy.squashed(CGPoint(x: 40, y: 42))
            let foot = CGPoint(x: capy.origin.x + p.x * World.capyScale,
                               y: capy.origin.y - (p.y + capy.drop) * World.capyScale + 1.3 * World.birdScale * (1 - sink))
            let f = b.footOffset
            return CGPoint(x: foot.x - f.dx, y: foot.y - f.dy)
        }

        static func departing(_ side: LinkMarkSide, _ t: CGFloat, _ from: CGFloat?) -> Rig {
            let duration = CGFloat(LinkMark.departDuration)
            let liftoff: CGFloat = 0.1
            var b: Bird
            var capy = Capy()
            if let p0 = from {
                b = Flight.hover(p0 + t * duration * beatsPerSecond)
            } else {
                // Take off from the back: wings open on the way up, the push-off at the top of the
                // first stroke; the capybara feels it leave.
                let h = Flight.hover((t - liftoff) * duration * beatsPerSecond)
                b = h
                let o = smooth(ramp(t, 0, 0.2))
                b.open = o
                b.arm = mix(Bird.fold, h.arm, o)
                b.hand = mix(Bird.fold, h.hand, o)
                b.flex = h.flex * o
                b.at = mix(World.restAt, h.at, Curve(0.45, 0, 0.3, 1)(ramp(t, liftoff - 0.02, 0.42)))
                b.standing = mix(.standing, h.standing, smooth(ramp(t, liftoff, 0.4)))
                b.folded = mix(.folded, h.folded, smooth(ramp(t, 0.02, 0.3)))
                b.head = mix(.zero, h.head, smooth(ramp(t, 0, 0.5)))
                b.pitch = mix(0, h.pitch, smooth(ramp(t, 0, 0.5)))
                let tau = (t - liftoff) * duration
                let win = 1 - smoother(ramp(t, 0.55, 0.85))
                capy.squash = 0.018 * tap(tau, hz: 1.8, damping: 0.72) * win
                capy.ear = 0.35 * tap(tau - 0.05, hz: 4.2, damping: 0.6) * win
            }
            let shared = 1 - smooth(ramp(t, 0.25, 0.95))
            let e = 1 - Curve(0.45, 0, 0.25, 1)(ramp(t, 0.3, 1))

            switch side {
            case .capybara:
                // Off to the top right, climbing and speeding up, neck out, legs trailing.
                let s = Curve(0.5, 0, 0.9, 0.55)(ramp(t, from == nil ? 0.15 : 0, 1))
                let off = bezier(.zero, CGPoint(x: 50, y: 100), CGPoint(x: 300, y: 270), CGPoint(x: 780, y: 560), s)
                b.at = CGPoint(x: b.at.x + off.x, y: b.at.y + off.y)
                let f = smooth(ramp(t, from == nil ? 0.2 : 0.05, 0.7))
                b.pitch = mix(b.pitch, 0.3, f)
                b.standing = mix(b.standing, Flight.trailing, f)
                b.folded = mix(b.folded, Flight.trailingFolded, f)
                b.head = mix(b.head, CGVector(dx: 5, dy: 3), f)
                return Rig(camera: Camera(.capybara, e), plate: Plate(side: .capybara, shared: shared), capy: capy, bird: b)
            case .flamingo:
                // The flamingo rises clear while the capybara backs out to the left, then comes
                // down to its own spot.
                b.at.y += (World.clearAt.y - World.hoverAt.y) * smooth(ramp(t, 0.1, 0.4)) * (1 - smooth(ramp(t, 0.55, 0.8)))
                let u = Curve(0.5, 0, 0.7, 0.55)(ramp(t, 0.12, 0.8))
                var walk = Gait.walking(-Gait.walkOut * u, env: smooth(ramp(u, 0, 0.1)))
                walk.squash = capy.squash
                walk.ear = capy.ear
                capy = walk
                let d = Curve(0.45, 0, 0.35, 1)(ramp(t, 0.45, 0.88))
                b.at = mix(b.at, World.groundAt, d)
                let flare = smooth(ramp(t, 0.55, 0.82))
                let fold = smooth(ramp(t, 0.8, 1))
                b.arm = mix(mix(b.arm, Flight.flareArm, flare), Bird.fold, fold)
                b.hand = mix(mix(b.hand, Flight.flareHand, flare), Bird.fold, fold)
                b.flex = b.flex * (1 - flare)
                b.open = mix(b.open, 0, fold)
                b.standing = mix(b.standing, .standing, smooth(ramp(t, 0.5, 0.82)))
                b.folded = mix(b.folded, .folded, Curve(0.4, 0, 0.2, 1)(ramp(t, 0.84, 1)))
                b.head = mix(b.head, .zero, smooth(ramp(t, 0.45, 1)))
                b.pitch = mix(b.pitch, 0, smooth(ramp(t, 0.45, 0.88)))
                return Rig(camera: Camera(.flamingo, e, tracking: b.at), plate: Plate(side: .flamingo, shared: shared), capy: capy, bird: b)
            }
        }
    }
}

extension LinkMark {
    /// The flamingo in the air.
    enum Flight {
        static let flareArm: CGFloat = 1.05
        static let flareHand: CGFloat = 1.2
        static let dangle = Leg(thigh: -0.25, shin: -0.55)
        static let dangleFolded = Leg(thigh: -0.08, shin: -0.78)
        static let calmDangle = Leg(thigh: -0.12, shin: -0.6)
        static let trailing = Leg(thigh: -1.15, shin: -1.35)
        static let trailingFolded = Leg(thigh: -1.05, shin: -1.42)

        /// Hovering at phase `p` (period 1): a full wing beat, the body lifted on each downstroke,
        /// the head held steadier than the body, legs swinging a beat behind.
        static func hover(_ p: CGFloat) -> Bird {
            let bob = 5 * sin(2 * .pi * (p - 0.2))
            var b = Bird(at: CGPoint(x: World.hoverAt.x, y: World.hoverAt.y + bob))
            b.pitch = 0.06
            b.open = 1
            let w = warp(p)
            b.arm = 0.35 + 0.85 * cos(2 * .pi * w)
            b.hand = 0.35 + 0.95 * cos(2 * .pi * warp(p - 0.07))
            b.flex = max(0, -sin(2 * .pi * w))
            b.head = CGVector(dx: 1.5, dy: 0.6 * bob / World.birdScale)
            let sway = 0.06 * sin(2 * .pi * (p - 0.35))
            b.standing = Leg(thigh: dangle.thigh + sway, shin: dangle.shin + 1.4 * sway)
            b.folded = Leg(thigh: dangleFolded.thigh + sway, shin: dangleFolded.shin + 1.4 * sway)
            return b
        }

        /// Downstroke quicker than the upstroke: phase 0 is the top, the bottom comes at ~0.43.
        static func warp(_ p: CGFloat) -> CGFloat { p + 0.25 * (1 - cos(2 * .pi * p)) / (2 * .pi) }
    }

    /// The capybara's walk: diagonal pairs, the phase tied to ground covered so feet don't skate.
    enum Gait {
        static let swing: CGFloat = 0.36
        static let stride: CGFloat = 4 * 18 * sin(swing)    // box units per cycle: 18 is hip to sole
        static let lift: CGFloat = 2.2
        static let walkIn: CGFloat = 560
        static let walkOut: CGFloat = 640

        /// A capybara `dx` world units from where it stands together. `env` fades the stride.
        static func walking(_ dx: CGFloat, env: CGFloat) -> Capy {
            var c = Capy(origin: CGPoint(x: World.capyOrigin.x + dx, y: World.capyOrigin.y))
            let a = 2 * .pi * dx / (stride * World.capyScale)
            let s = swing * env * sin(a), k = cos(a)
            c.front = s
            c.back = -s
            // The leg swinging forward relative to the body is the one in the air.
            c.frontLift = lift * env * max(0, k) * max(0, k)
            c.backLift = lift * env * max(0, -k) * max(0, -k)
            c.drop = 18 * (1 - cos(s))
            return c
        }
    }

    // MARK: - Drawing

    enum Painter {
        static let white = CGColor(gray: 1, alpha: 1)
        /// Flamingo's beak tip, #331C24.
        static let beakTip = CGColor(srgbRed: 0.20, green: 0.11, blue: 0.14, alpha: 1)

        static func icon(_ rig: Rig, _ ctx: CGContext, _ rect: CGRect) {
            let s = min(rect.width, rect.height)
            guard s > 0 else { return }
            let o = CGPoint(x: rect.midX - s / 2, y: rect.midY - s / 2)
            let k = s / 1024
            // Shadows are set in device space; keep them in proportion under a scaled CTM.
            let d = ctx.userSpaceToDeviceSpaceTransform
            let f = abs(d.a * d.d - d.b * d.c).squareRoot()
            let look = Look(rig.plate)

            // The plate. Capybara's own is make-icon.swift's rounded rect, with its numbers exactly.
            let plate: CGRect, shape: CGPath, radius: CGFloat, shadowY: CGFloat, blur: CGFloat
            if look.roundness == 0 {
                let inset = s * 100 / 1024
                plate = CGRect(x: o.x + inset, y: o.y + inset, width: s - 2 * inset, height: s - 2 * inset)
                radius = plate.width * 0.225
                shape = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)
                shadowY = -s * 0.012
                blur = s * 0.03
            } else {
                plate = CGRect(x: o.x + 100 * k, y: o.y + 100 * k, width: 824 * k, height: 824 * k)
                radius = 185.4 * k
                shape = look.roundness >= 1 ? Squircle.path(in: plate, radius: radius)
                    : Squircle.morph(in: plate, radius: radius, offset: 0, look.roundness)
                shadowY = -look.shadowY * k
                blur = look.blur * k
            }
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: shadowY * f), blur: blur * f, color: CGColor(gray: 0, alpha: 0.28))
            ctx.addPath(shape)
            ctx.setFillColor(look.base.color)
            ctx.fillPath()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addPath(shape)
            ctx.clip()
            if let space = CGColorSpace(name: CGColorSpace.sRGB),
               let g = CGGradient(colorsSpace: space, colors: [look.top.color, look.bottom.color] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: plate.maxY), end: CGPoint(x: 0, y: plate.minY), options: [])
            }
            if look.edge > 0 {
                // Flamingo's faint inner edge, so the plate holds on dark Docks.
                let edge = max(1, 4 * k)
                let ring = look.roundness >= 1 ? Squircle.path(in: plate, radius: radius, offset: edge / 2)
                    : Squircle.morph(in: plate, radius: radius, offset: edge / 2, look.roundness)
                ctx.addPath(ring)
                ctx.setStrokeColor(CGColor(gray: 1, alpha: look.edge))
                ctx.setLineWidth(edge)
                ctx.strokePath()
            }

            // The animals, on the plate, with Flamingo's soft lift.
            let canvas = CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: o.x, ty: o.y)
            let lifted = look.lift > 0
            if lifted {
                ctx.setShadow(offset: CGSize(width: 0, height: -6 * k * f), blur: 14 * k * f, color: CGColor(gray: 0, alpha: look.lift))
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            animals(rig, ctx, canvas: canvas, stage: plate.insetBy(dx: -40 * k, dy: -40 * k), body: white, tip: beakTip)
            if lifted { ctx.endTransparencyLayer() }
            ctx.restoreGState()
        }

        static func mark(_ rig: Rig, _ ctx: CGContext, _ rect: CGRect, _ color: CGColor) {
            let s = min(rect.width, rect.height)
            guard s > 0 else { return }
            let stage = CGRect(x: rect.midX - s / 2, y: rect.midY - s / 2, width: s, height: s)
            let k = s / 824
            let canvas = CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: stage.minX - 100 * k, ty: stage.minY - 100 * k)
            let solid = color.copy(alpha: 1) ?? color
            ctx.saveGState()
            ctx.clip(to: stage)
            ctx.setAlpha(color.alpha)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            animals(rig, ctx, canvas: canvas, stage: stage, body: solid, tip: solid)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }

        /// Both animals, `canvas` mapping the 1024 canvas to the context. Anything wholly outside
        /// `stage` is skipped (it would only add a sliver of shadow).
        static func animals(_ rig: Rig, _ ctx: CGContext, canvas: CGAffineTransform, stage: CGRect, body: CGColor, tip: CGColor) {
            let view = rig.camera.transform.concatenating(canvas)
            ctx.setFillColor(body)

            // Capybara.
            let c = rig.capy
            let capyT = CGAffineTransform(translationX: c.origin.x, y: c.origin.y)
                .scaledBy(x: World.capyScale, y: -World.capyScale).translatedBy(x: 0, y: c.drop)
                .concatenating(view)
            if Shapes.capyBounds.applying(capyT).intersects(stage) {
                if c.isRest {
                    fill(ctx, Shapes.capybara, capyT)
                } else {
                    let squash = CGAffineTransform(translationX: 50, y: 76).scaledBy(x: 1 + 0.4 * c.squash, y: 1 - c.squash)
                        .translatedBy(x: -50, y: -76)
                    let torso = squash.concatenating(capyT)
                    fill(ctx, Shapes.capyTorso, torso)
                    fill(ctx, Shapes.capyEar, rotation(-c.ear, about: CGPoint(x: 61, y: 30)).concatenating(torso))
                    for (hip, swing, lift) in [(CGPoint(x: 25, y: 66), c.back, c.backLift), (CGPoint(x: 63, y: 66), c.front, c.frontLift)] {
                        let leg = CGAffineTransform(translationX: hip.x, y: hip.y).rotated(by: -swing).translatedBy(x: 0, y: -lift)
                        fill(ctx, Shapes.capyLeg, leg.concatenating(capyT))
                    }
                }
            }

            // Flamingo.
            let b = rig.bird
            let birdT = b.transform.concatenating(view)
            guard Shapes.birdBoundsLoose.applying(birdT).intersects(stage) else { return }
            if b.isRest {
                fill(ctx, Shapes.birdRest, birdT)
                ctx.setFillColor(tip)
                fill(ctx, Shapes.tipRest, birdT)
                return
            }
            let headT = CGAffineTransform(translationX: b.head.dx, y: b.head.dy)
            fill(ctx, Shapes.birdBody, birdT)
            if b.open > 0 { fill(ctx, Shapes.wing(b), birdT) }
            fill(ctx, Shapes.neck(head: b.head), birdT)
            fill(ctx, Shapes.birdHead, headT.concatenating(birdT))
            fill(ctx, Shapes.beakWhite, headT.concatenating(birdT))
            // Legs: round-capped strokes, as in the mark.
            ctx.saveGState()
            ctx.concatenate(birdT)
            let a = Shapes.joints(hip: Shapes.standingHip, b.standing, Shapes.standingLengths)
            let z = Shapes.joints(hip: Shapes.foldedHip, b.folded, Shapes.foldedLengths)
            ctx.addLines(between: [Shapes.standingHip, a.knee, a.foot])
            ctx.addLines(between: [Shapes.foldedHip, z.knee, z.foot])
            ctx.setLineWidth(Shapes.legWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(body)
            ctx.strokePath()
            ctx.restoreGState()
            ctx.setFillColor(tip)
            fill(ctx, Shapes.beakDark, headT.concatenating(birdT))
        }

        static func fill(_ ctx: CGContext, _ path: CGPath, _ t: CGAffineTransform) {
            var t = t
            guard let p = path.copy(using: &t) else { return }
            ctx.addPath(p)
            ctx.fillPath()
        }

        static func rotation(_ a: CGFloat, about p: CGPoint) -> CGAffineTransform {
            CGAffineTransform(translationX: p.x, y: p.y).rotated(by: a).translatedBy(x: -p.x, y: -p.y)
        }
    }

    /// The plate for a frame: each app's own, the shared one, or a blend.
    struct Look {
        struct RGB {
            var r: CGFloat, g: CGFloat, b: CGFloat
            var color: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
            static func blend(_ a: RGB, _ c: RGB, _ w: CGFloat) -> RGB {
                RGB(r: mix(a.r, c.r, w), g: mix(a.g, c.g, w), b: mix(a.b, c.b, w))
            }
        }

        var roundness: CGFloat      // 0 Capybara's rounded rect … 1 Flamingo's squircle
        var shadowY: CGFloat, blur: CGFloat
        var base: RGB, top: RGB, bottom: RGB
        var edge: CGFloat           // inner edge line's alpha
        var lift: CGFloat           // the animals' soft shadow's alpha

        /// Capybara's make-icon.swift.
        static let capybara = Look(roundness: 0, shadowY: 12.288, blur: 30.72,
                                   base: RGB(r: 0.9, g: 0.33, b: 0.4),
                                   top: RGB(r: 1.0, g: 0.56, b: 0.6), bottom: RGB(r: 0.84, g: 0.25, b: 0.36),
                                   edge: 0, lift: 0)
        /// Flamingo's make-icon.swift: #FF8D96 to #EA4D68.
        static let flamingo = Look(roundness: 1, shadowY: 10, blur: 24,
                                   base: RGB(r: 0.918, g: 0.302, b: 0.408),
                                   top: RGB(r: 1.00, g: 0.553, b: 0.588), bottom: RGB(r: 0.918, g: 0.302, b: 0.408),
                                   edge: 0.18, lift: 0.16)
        /// Together: the two corals met halfway, on Flamingo's squircle.
        static let shared = Look(roundness: 1, shadowY: 11.144, blur: 27.36,
                                 base: RGB(r: 0.879, g: 0.276, b: 0.384),
                                 top: RGB(r: 1.0, g: 0.5565, b: 0.594), bottom: RGB(r: 0.879, g: 0.276, b: 0.384),
                                 edge: 0.18, lift: 0.16)

        init(roundness: CGFloat, shadowY: CGFloat, blur: CGFloat, base: RGB, top: RGB, bottom: RGB, edge: CGFloat, lift: CGFloat) {
            self.roundness = roundness; self.shadowY = shadowY; self.blur = blur
            self.base = base; self.top = top; self.bottom = bottom; self.edge = edge; self.lift = lift
        }

        init(_ plate: Plate) {
            let a = plate.side == .capybara ? Look.capybara : Look.flamingo, c = Look.shared, w = plate.shared
            self.init(roundness: mix(a.roundness, c.roundness, w), shadowY: mix(a.shadowY, c.shadowY, w),
                      blur: mix(a.blur, c.blur, w), base: .blend(a.base, c.base, w), top: .blend(a.top, c.top, w),
                      bottom: .blend(a.bottom, c.bottom, w), edge: mix(a.edge, c.edge, w), lift: mix(a.lift, c.lift, w))
        }
    }

    // MARK: - Geometry

    /// Every static shape, built once. Capybara parts are in make-icon.swift's 100×100 box,
    /// flamingo parts in FlamingoMarkPath's, both y down.
    enum Shapes {
        static func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
            CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
        }

        // Capybara: exactly make-icon.swift's capybara(), and the same shape in moving parts.
        nonisolated(unsafe) static let capybara: CGPath = {
            var shape = rr(10, 42, 64, 34, 17)                          // body
            shape = shape.union(rr(52, 30, 34, 30, 12))                 // head
            shape = shape.union(rr(70, 36, 20, 24, 8))                  // snout
            shape = shape.union(CGPath(ellipseIn: CGRect(x: 56, y: 25, width: 10, height: 10), transform: nil)) // ear
            shape = shape.union(rr(20, 64, 10, 20, 4.5))                // back leg
            shape = shape.union(rr(58, 64, 10, 20, 4.5))                // front leg
            let eye = CGPath(ellipseIn: CGRect(x: 72.5, y: 39, width: 5.2, height: 5.2), transform: nil)
            let nostril = CGPath(ellipseIn: CGRect(x: 85, y: 43, width: 2.6, height: 3.2), transform: nil)
            return shape.subtracting(eye).subtracting(nostril)
        }()
        /// Body, head and snout, eye and nostril cut out.
        nonisolated(unsafe) static let capyTorso: CGPath = {
            let eye = CGPath(ellipseIn: CGRect(x: 72.5, y: 39, width: 5.2, height: 5.2), transform: nil)
            let nostril = CGPath(ellipseIn: CGRect(x: 85, y: 43, width: 2.6, height: 3.2), transform: nil)
            return rr(10, 42, 64, 34, 17).union(rr(52, 30, 34, 30, 12)).union(rr(70, 36, 20, 24, 8))
                .subtracting(eye).subtracting(nostril)
        }()
        nonisolated(unsafe) static let capyEar = CGPath(ellipseIn: CGRect(x: 56, y: 25, width: 10, height: 10), transform: nil)
        /// A leg around its hip pivot (2 below the top, centred).
        nonisolated(unsafe) static let capyLeg = rr(-5, -2, 10, 20, 4.5)
        static let capyBounds = CGRect(x: 0, y: 15, width: 100, height: 80)

        // Flamingo: FlamingoMarkPath's geometry, copied (that module imports SwiftUI).
        static let legWidth: CGFloat = 2.6

        nonisolated(unsafe) static let birdBody: CGPath = {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 58, y: 48.4))
            // chest, wrapping the base of the neck
            p.addCurve(to: CGPoint(x: 68, y: 66), control1: CGPoint(x: 71.6, y: 47.2), control2: CGPoint(x: 75.6, y: 58))
            // belly, running out into a short drooping tail
            p.addCurve(to: CGPoint(x: 22.5, y: 66.6), control1: CGPoint(x: 60, y: 73.6), control2: CGPoint(x: 38, y: 76))
            // back, up to the shoulder
            p.addCurve(to: CGPoint(x: 58, y: 48.4), control1: CGPoint(x: 31, y: 55), control2: CGPoint(x: 45, y: 47.4))
            p.closeSubpath()
            return p
        }()

        /// The neck's centre line: thick where it leaves the chest, slender under the head.
        static let neckLine: [Cubic] = [
            (CGPoint(x: 64, y: 58), CGPoint(x: 69.5, y: 45), CGPoint(x: 50, y: 44), CGPoint(x: 50, y: 32)),
            (CGPoint(x: 50, y: 32), CGPoint(x: 50, y: 22), CGPoint(x: 55, y: 16), CGPoint(x: 59.5, y: 14)),
        ]
        static let neckWidths: (CGFloat, CGFloat) = (7.6, 4.4)

        nonisolated(unsafe) static let birdHead = CGPath(ellipseIn: CGRect(x: 54.5, y: 6.5, width: 11, height: 11), transform: nil)

        nonisolated(unsafe) static let beak: CGPath = {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 59, y: 6.7))
            // upper mandible, nearly straight
            p.addCurve(to: CGPoint(x: 71, y: 9.6), control1: CGPoint(x: 63.5, y: 6.1), control2: CGPoint(x: 68, y: 6.9))
            // the bend, down to the tip
            p.addCurve(to: CGPoint(x: 73.4, y: 22), control1: CGPoint(x: 74.6, y: 12.6), control2: CGPoint(x: 75.2, y: 18.4))
            // inside of the tip, back up to the bend
            p.addCurve(to: CGPoint(x: 70.2, y: 15.4), control1: CGPoint(x: 71.8, y: 19.8), control2: CGPoint(x: 71.2, y: 16.8))
            // underside, back to the throat
            p.addCurve(to: CGPoint(x: 61, y: 17.4), control1: CGPoint(x: 67.6, y: 14), control2: CGPoint(x: 64, y: 16.6))
            p.closeSubpath()
            return p
        }()

        /// Everything of the beak past the bend.
        nonisolated(unsafe) static let beakTipArea: CGPath = {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 71.6, y: 6))
            p.addLine(to: CGPoint(x: 82, y: 12))
            p.addLine(to: CGPoint(x: 82, y: 30))
            p.addLine(to: CGPoint(x: 66, y: 30))
            p.addLine(to: CGPoint(x: 69.4, y: 15))
            p.closeSubpath()
            return p
        }()

        nonisolated(unsafe) static let restLegs: CGPath = {
            let p = CGMutablePath()
            // standing leg
            p.move(to: CGPoint(x: 48, y: 70))
            p.addLine(to: CGPoint(x: 48, y: 95))
            // folded leg: down and forward to the joint, back to the standing leg
            p.move(to: CGPoint(x: 52, y: 70))
            p.addLine(to: CGPoint(x: 59, y: 80))
            p.addLine(to: CGPoint(x: 48, y: 84))
            return p
        }()

        /// FlamingoMarkPath.silhouette, built the same way.
        nonisolated(unsafe) static let silhouette: CGPath = {
            var shape: CGPath = birdBody
            shape = shape.union(taper(neckLine, from: neckWidths.0, to: neckWidths.1, caps: true).normalized())
            shape = shape.union(birdHead)
            shape = shape.union(beak)
            shape = shape.union(restLegs.copy(strokingWithWidth: legWidth, lineCap: .round, lineJoin: .round, miterLimit: 4))
            return shape
        }()
        static let birdBounds: CGRect = silhouette.boundingBoxOfPath
        static let birdBoundsLoose = CGRect(x: 8, y: -2, width: 86, height: 102)
        /// The bird at rest, white and dark parts, exactly as Flamingo's icon draws them.
        nonisolated(unsafe) static let birdRest: CGPath = silhouette.subtracting(beakTipArea)
        nonisolated(unsafe) static let tipRest: CGPath = silhouette.intersection(beakTipArea)
        nonisolated(unsafe) static let beakWhite: CGPath = beak.subtracting(beakTipArea)
        nonisolated(unsafe) static let beakDark: CGPath = beak.intersection(beakTipArea)

        // Legs as joints: hip, knee, foot.
        static let standingHip = CGPoint(x: 48, y: 70)
        static let foldedHip = CGPoint(x: 52, y: 70)
        static let standingLengths: (CGFloat, CGFloat) = (12.5, 12.5)
        static let foldedLengths: (CGFloat, CGFloat) = ((49 + 100 as CGFloat).squareRoot(), (121 + 16 as CGFloat).squareRoot())

        static func joints(hip: CGPoint, _ leg: Leg, _ l: (CGFloat, CGFloat)) -> (knee: CGPoint, foot: CGPoint) {
            let knee = CGPoint(x: hip.x + l.0 * sin(leg.thigh), y: hip.y + l.0 * cos(leg.thigh))
            return (knee, CGPoint(x: knee.x + l.1 * sin(leg.shin), y: knee.y + l.1 * cos(leg.shin)))
        }

        /// The neck from chest to a head moved by `head`: the end and its last handle ride with the
        /// head, the middle of the S follows halfway.
        static func neck(head d: CGVector) -> CGPath {
            let a = neckLine[0], b = neckLine[1]
            func m(_ p: CGPoint, _ w: CGFloat) -> CGPoint { CGPoint(x: p.x + d.dx * w, y: p.y + d.dy * w) }
            return taper([(a.0, a.1, m(a.2, 0.35), m(a.3, 0.5)), (m(b.0, 0.5), m(b.1, 0.65), m(b.2, 1), m(b.3, 1))],
                         from: neckWidths.0, to: neckWidths.1, caps: false)
        }

        /// The wing's outline, laid flat: x along the body, y out along the span (box units).
        /// Root from x 36 to 48 along the back, behind the neck: a rounded leading edge out to
        /// the wrist, primaries sweeping back to a pointed tip, the trailing edge curving into the back.
        static let wingPlan: [Cubic] = [
            (CGPoint(x: 48, y: 0), CGPoint(x: 50, y: 9), CGPoint(x: 49.5, y: 17), CGPoint(x: 47.5, y: 23)),
            (CGPoint(x: 47.5, y: 23), CGPoint(x: 46, y: 36), CGPoint(x: 41, y: 47), CGPoint(x: 33, y: 54)),
            (CGPoint(x: 33, y: 54), CGPoint(x: 31, y: 47), CGPoint(x: 29.5, y: 40), CGPoint(x: 29.5, y: 32)),
            (CGPoint(x: 29.5, y: 32), CGPoint(x: 29.5, y: 20), CGPoint(x: 32, y: 8), CGPoint(x: 36, y: 0)),
        ]
        static let wristSpan: CGFloat = 23

        /// The near wing seen from the side: its span foreshortened by the sine of its elevation,
        /// the hand past the wrist at its own (lagging) angle and tucked on the upstroke. The
        /// stroke plane leans, so the tip rises up and back and comes down and forward. Folding
        /// shrinks it into the shoulder, inside the body.
        static func wing(_ b: Bird) -> CGPath {
            let o = b.open, sa = sin(b.arm), sh = sin(b.hand)
            let wrist = wristSpan * o, tuck = 1 - 0.3 * b.flex
            func project(_ q: CGPoint) -> CGPoint {
                let v = q.y * o
                let x = 39 + (q.x - 39) * (0.5 + 0.5 * o)
                let arm = min(v, wrist), hand = max(0, v - wrist) * tuck
                let rise = arm * sa + hand * sh
                let root = 62 - (x - 27) * 10 / 21
                return CGPoint(x: x - 0.3 * rise - hand * 0.35 * b.flex, y: root - rise)
            }
            let p = CGMutablePath()
            p.move(to: project(wingPlan[0].0))
            for c in wingPlan { p.addCurve(to: project(c.3), control1: project(c.1), control2: project(c.2)) }
            p.closeSubpath()
            return p
        }

        typealias Cubic = (CGPoint, CGPoint, CGPoint, CGPoint)

        /// A filled outline around a chain of cubics whose width goes linearly from `w0` to `w1`
        /// (FlamingoMarkPath.taper; `caps` adds its round ends).
        static func taper(_ segments: [Cubic], from w0: CGFloat, to w1: CGFloat, caps: Bool) -> CGPath {
            let steps = caps ? 48 : 24
            var center: [(CGPoint, CGPoint)] = []   // point, unit tangent
            center.reserveCapacity(segments.count * steps + 1)
            for (i, c) in segments.enumerated() {
                for k in (i == 0 ? 0 : 1)...steps {
                    let t = CGFloat(k) / CGFloat(steps)
                    center.append((cubic(c, t), unit(cubicTangent(c, t))))
                }
            }
            var left: [CGPoint] = [], right: [CGPoint] = []
            left.reserveCapacity(center.count); right.reserveCapacity(center.count)
            for (i, (pt, tan)) in center.enumerated() {
                let w = (w0 + (w1 - w0) * CGFloat(i) / CGFloat(center.count - 1)) / 2
                let n = CGPoint(x: -tan.y, y: tan.x)
                left.append(CGPoint(x: pt.x + n.x * w, y: pt.y + n.y * w))
                right.append(CGPoint(x: pt.x - n.x * w, y: pt.y - n.y * w))
            }
            let p = CGMutablePath()
            p.addLines(between: left + right.reversed())
            p.closeSubpath()
            if caps {
                // Round both ends so the joins into body and head stay smooth.
                p.addEllipse(in: CGRect(x: center[0].0.x - w0 / 2, y: center[0].0.y - w0 / 2, width: w0, height: w0))
                let e = center[center.count - 1].0
                p.addEllipse(in: CGRect(x: e.x - w1 / 2, y: e.y - w1 / 2, width: w1, height: w1))
            }
            return p
        }

        static func cubic(_ c: Cubic, _ t: CGFloat) -> CGPoint {
            let u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, d = 3 * u * t * t, e = t * t * t
            return CGPoint(x: a * c.0.x + b * c.1.x + d * c.2.x + e * c.3.x,
                           y: a * c.0.y + b * c.1.y + d * c.2.y + e * c.3.y)
        }

        static func cubicTangent(_ c: Cubic, _ t: CGFloat) -> CGPoint {
            let u = 1 - t
            let a = 3 * u * u, b = 6 * u * t, d = 3 * t * t
            return CGPoint(x: a * (c.1.x - c.0.x) + b * (c.2.x - c.1.x) + d * (c.3.x - c.2.x),
                           y: a * (c.1.y - c.0.y) + b * (c.2.y - c.1.y) + d * (c.3.y - c.2.y))
        }

        static func unit(_ v: CGPoint) -> CGPoint {
            let l = max((v.x * v.x + v.y * v.y).squareRoot(), 0.0001)
            return CGPoint(x: v.x / l, y: v.y / l)
        }
    }

    /// Flamingo's continuous-curvature rounded rectangle (FlamingoDesign/Squircle.swift, geometry
    /// only), and a blend from an ordinary rounded rectangle into it for Capybara's plate.
    enum Squircle {
        static let extent: CGFloat = 1.528
        static let apex: CGFloat = 1 - 1 / 2.squareRoot()
        static let handle: CGFloat = 1.08

        static func effectiveRadius(_ radius: CGFloat, in rect: CGRect) -> CGFloat {
            max(0, min(radius, min(rect.width, rect.height) / (2 * extent)))
        }

        typealias Corner = (v: CGPoint, u: CGVector, w: CGVector)

        static func corners(_ rect: CGRect) -> [Corner] {
            [
                (CGPoint(x: rect.maxX, y: rect.minY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: 1)),
                (CGPoint(x: rect.maxX, y: rect.maxY), CGVector(dx: 0, dy: -1), CGVector(dx: -1, dy: 0)),
                (CGPoint(x: rect.minX, y: rect.maxY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: -1)),
                (CGPoint(x: rect.minX, y: rect.minY), CGVector(dx: 0, dy: 1), CGVector(dx: 1, dy: 0)),
            ]
        }

        static func point(_ c: Corner, _ along: CGFloat, _ across: CGFloat) -> CGPoint {
            CGPoint(x: c.v.x + c.u.dx * along + c.w.dx * across, y: c.v.y + c.u.dy * along + c.w.dy * across)
        }

        /// Exactly SquircleGeometry.path.
        static func path(in rect: CGRect, radius: CGFloat, offset d: CGFloat = 0) -> CGPath {
            let path = CGMutablePath()
            guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0, radius.isFinite, d.isFinite,
                  2 * d < min(rect.width, rect.height) else { return path }
            let r = effectiveRadius(radius, in: rect)
            guard r > 0.01, d < r else {
                path.addRect(rect.insetBy(dx: d, dy: d))
                return path
            }
            let a = extent * r, s = apex * r, h = handle * r
            let tangent = 2 * s + d * (2.squareRoot() - 1)
            let tip = s + d / 2.squareRoot()
            let corners = corners(rect)
            let last = corners[3]
            path.move(to: point(last, d, a))
            for c in corners {
                path.addLine(to: point(c, a, d))
                path.addCurve(to: point(c, tip, tip), control1: point(c, h, d), control2: point(c, tangent, d))
                path.addCurve(to: point(c, d, a), control1: point(c, d, tangent), control2: point(c, d, h))
            }
            path.closeSubpath()
            return path
        }

        /// `m` 0 is a circular-cornered rounded rectangle (each corner two 45° cubics), 1 the
        /// squircle; between, every control point moves straight across. Both pass the same apex.
        static func morph(in rect: CGRect, radius: CGFloat, offset d: CGFloat, _ m: CGFloat) -> CGPath {
            let path = CGMutablePath()
            let r = effectiveRadius(radius, in: rect)
            guard r > 0.01, d < r, 2 * d < min(rect.width, rect.height) else {
                path.addRect(rect.insetBy(dx: d, dy: d))
                return path
            }
            // Squircle legs.
            let a = extent * r, s = apex * r, h = handle * r
            let tangent = 2 * s + d * (2.squareRoot() - 1)
            let tip = s + d / 2.squareRoot()
            // Circle of radius r − d about the same centre; handle for a 45° arc.
            let q = r - d, k = q * 0.265216489, ax = r - q / 2.squareRoot(), kk = k / 2.squareRoot()
            func p(_ c: Corner, _ round: (CGFloat, CGFloat), _ sq: (CGFloat, CGFloat)) -> CGPoint {
                point(c, mix(round.0, sq.0, m), mix(round.1, sq.1, m))
            }
            let corners = corners(rect)
            path.move(to: p(corners[3], (d, r), (d, a)))
            for c in corners {
                path.addLine(to: p(c, (r, d), (a, d)))
                path.addCurve(to: p(c, (ax, ax), (tip, tip)), control1: p(c, (r - k, d), (h, d)),
                              control2: p(c, (ax + kk, ax - kk), (tangent, d)))
                path.addCurve(to: p(c, (d, r), (d, a)), control1: p(c, (ax - kk, ax + kk), (d, tangent)),
                              control2: p(c, (d, r - k), (d, h)))
            }
            path.closeSubpath()
            return path
        }
    }

    // MARK: - Easing

    /// A CSS-style cubic-Bézier timing curve through (0, 0) and (1, 1).
    struct Curve {
        let x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat

        init(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
            self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2
        }

        func callAsFunction(_ x: CGFloat) -> CGFloat {
            if x <= 0 { return 0 }
            if x >= 1 { return 1 }
            func f(_ s: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
                let u = 1 - s
                return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s
            }
            // Newton, then bisection if it wanders.
            var s = x
            for _ in 0..<6 {
                let e = f(s, x1, x2) - x
                if abs(e) < 1e-7 { return f(s, y1, y2) }
                let u = 1 - s
                let dx = 3 * u * u * x1 + 6 * u * s * (x2 - x1) + 3 * s * s * (1 - x2)
                if abs(dx) < 1e-6 { break }
                s -= e / dx
                if s < 0 || s > 1 { break }
            }
            var lo: CGFloat = 0, hi: CGFloat = 1
            s = x
            for _ in 0..<30 {
                if f(s, x1, x2) < x { lo = s } else { hi = s }
                s = (lo + hi) / 2
            }
            return f(s, y1, y2)
        }
    }
}

// MARK: - Helpers

/// Clamped to 0…1; NaN to 0.
fileprivate func unit(_ t: Double) -> CGFloat { t.isNaN ? 0 : CGFloat(min(max(t, 0), 1)) }
fileprivate func ramp(_ t: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat { min(max((t - a) / (b - a), 0), 1) }
fileprivate func smooth(_ x: CGFloat) -> CGFloat { x * x * (3 - 2 * x) }
fileprivate func smoother(_ x: CGFloat) -> CGFloat { x * x * x * (x * (6 * x - 15) + 10) }
fileprivate func fract(_ x: CGFloat) -> CGFloat { x - x.rounded(.down) }

/// Exact at both ends: w 0 gives `a`, w 1 gives `b`, bit for bit.
fileprivate func mix(_ a: CGFloat, _ b: CGFloat, _ w: CGFloat) -> CGFloat { a * (1 - w) + b * w }
fileprivate func mix(_ a: CGPoint, _ b: CGPoint, _ w: CGFloat) -> CGPoint { CGPoint(x: mix(a.x, b.x, w), y: mix(a.y, b.y, w)) }
fileprivate func mix(_ a: CGVector, _ b: CGVector, _ w: CGFloat) -> CGVector { CGVector(dx: mix(a.dx, b.dx, w), dy: mix(a.dy, b.dy, w)) }
fileprivate func mix(_ a: LinkMark.Leg, _ b: LinkMark.Leg, _ w: CGFloat) -> LinkMark.Leg { LinkMark.Leg(thigh: mix(a.thigh, b.thigh, w), shin: mix(a.shin, b.shin, w)) }

fileprivate func bezier(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint, _ t: CGFloat) -> CGPoint {
    LinkMark.Shapes.cubic((a, b, c, d), t)
}

/// A tap on a damped spring: 0 until `tau` (seconds) passes 0, peaks at 1, then dies away.
fileprivate func tap(_ tau: CGFloat, hz: CGFloat, damping z: CGFloat) -> CGFloat {
    guard tau > 0 else { return 0 }
    let w = 2 * .pi * hz, wd = w * (1 - z * z).squareRoot()
    let peak = atan2((1 - z * z).squareRoot(), z) / wd
    return exp(-z * w * tau) * sin(wd * tau) / (exp(-z * w * peak) * sin(wd * peak))
}
