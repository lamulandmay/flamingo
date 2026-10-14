// Builds the Arc lamp as USDZ with named nodes (Base, LowerArm, UpperArm, Shade, Diffuser).
// Usage: swift make_lamp.swift <out.usdz>
import Foundation
import SceneKit

let outPath = CommandLine.arguments.dropFirst().first ?? "arc-lamp.usdz"

func material(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, metal: CGFloat = 0.8, rough: CGFloat = 0.45,
              emission: NSColor? = nil) -> SCNMaterial {
    let m = SCNMaterial()
    m.lightingModel = .physicallyBased
    m.diffuse.contents = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    m.metalness.contents = metal
    m.roughness.contents = rough
    if let emission { m.emission.contents = emission }
    return m
}

let graphite = material(0.20, 0.21, 0.23)
let bone = material(0.89, 0.86, 0.80, metal: 0.0, rough: 0.6)
let glow = material(1.0, 0.86, 0.66, metal: 0, rough: 1, emission: NSColor(srgbRed: 1, green: 0.8, blue: 0.55, alpha: 1))

// SceneKit's USD writer wants one material per geometry element (a cylinder has three).
func paint(_ node: SCNNode, _ m: SCNMaterial) {
    guard let g = node.geometry else { return }
    g.materials = Array(repeating: m, count: max(1, g.elementCount))
}

let scene = SCNScene()
let lamp = SCNNode()
lamp.name = "Arc"
scene.rootNode.addChildNode(lamp)

// Units are metres. Base 190 mm across.
let base = SCNNode(geometry: SCNCylinder(radius: 0.095, height: 0.022))
base.name = "Base"
paint(base, graphite)
base.position = SCNVector3(0, 0.011, 0)
lamp.addChildNode(base)

func arm(_ name: String, length: CGFloat, from: SCNVector3, angle: CGFloat) -> (SCNNode, SCNVector3) {
    let pivot = SCNNode()
    pivot.name = name
    pivot.position = from
    pivot.eulerAngles.z = angle
    let rod = SCNNode(geometry: SCNCylinder(radius: 0.007, height: length))
    rod.name = name + "Rod"
    paint(rod, graphite)
    rod.position = SCNVector3(0, length / 2, 0)
    pivot.addChildNode(rod)
    let hinge = SCNNode(geometry: SCNSphere(radius: 0.012))
    hinge.name = name + "Hinge"
    paint(hinge, graphite)
    pivot.addChildNode(hinge)
    lamp.addChildNode(pivot)
    let end = SCNVector3(from.x - sin(angle) * length, from.y + cos(angle) * length, from.z)
    return (pivot, end)
}

let (_, elbow) = arm("LowerArm", length: 0.36, from: SCNVector3(0, 0.03, 0), angle: -0.42)
let (_, wrist) = arm("UpperArm", length: 0.34, from: elbow, angle: -1.85)

// Shade: 150 mm diameter truncated cone, opening downward and tilted toward the desk.
let shade = SCNNode(geometry: SCNCone(topRadius: 0.028, bottomRadius: 0.075, height: 0.11))
shade.name = "Shade"
paint(shade, bone)
shade.position = SCNVector3(wrist.x, wrist.y - 0.04, wrist.z)
shade.eulerAngles.z = 0.35
lamp.addChildNode(shade)

let diffuser = SCNNode(geometry: SCNCylinder(radius: 0.071, height: 0.003))
diffuser.name = "Diffuser"
paint(diffuser, glow)
diffuser.position = SCNVector3(0, -0.054, 0)
shade.addChildNode(diffuser)

let url = URL(fileURLWithPath: outPath)
try? FileManager.default.removeItem(at: url)
guard scene.write(to: url, options: nil, delegate: nil, progressHandler: nil) else {
    FileHandle.standardError.write("SceneKit could not write \(outPath)\n".data(using: .utf8)!)
    exit(1)
}
