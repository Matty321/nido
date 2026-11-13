// SPDX-License-Identifier: Apache-2.0
//
// The script 04-icon.json: the app icon (S12, frame "AppIcon") on page Screens.
//
// Concept: a nest holding one egg, the place where virtual machines are kept and hatched. macOS
// icon grid: a 1024 × 1024 canvas with the rounded-rectangle body of 824 × 824 at (100, 100),
// corner radius 185, a soft shadow below. Few large shapes with strong value contrast (light egg,
// warm nest, deep green ground) so the icon still reads at 16 px. The icon is an image asset:
// its colours are fixed, not variables.

import Foundation

func iconScript(continuing screens: Script) -> Script {
    let s = Script(continuing: screens)
    s.selectPage(s.firstLayer(named: "Screens"))
    let x = 2 * (boardWidth + 200)
    let icon = s.freeFrame("AppIcon", parent: nil, x: x, y: 0, width: 1024, height: 1024)

    let body = s.freeFrame("Fondo", parent: icon, x: 100, y: 100, width: 824, height: 824, props: [
        "cornerRadius": 185, "cornerSmoothing": 0.6, "clip": true,
        "fills": [["type": "linearGradient", "stops": ["#2F9A87", "#134A42"], "from": [0.5, 0], "to": [0.5, 1]]],
        "effects": [["type": "dropShadow", "color": "#0000004D", "offset": [0, 10], "radius": 20, "spread": 0]],
    ])
    // A soft light behind the egg.
    s.ellipse(parent: body, x: 102, y: 70, width: 620, height: 620, props: [
        "fills": [["type": "radialGradient", "stops": ["#FFFFFF38", "#FFFFFF00"]]],
    ])
    // Inside of the nest, behind the egg (coordinates below are relative to the body).
    s.ellipse(parent: body, x: 112, y: 455, width: 600, height: 170, props: ["fills": ["#5E3A1B"]])
    // The egg: narrower at the top, its lower part hidden by the front of the nest.
    s.vector("Uovo", path: "M 412 214 C 506 214 562 382 562 474 C 562 562 496 616 412 616 "
                + "C 328 616 262 562 262 474 C 262 382 318 214 412 214 Z", parent: body, props: [
        "fills": [["type": "linearGradient", "stops": ["#FFFDF7", "#E6D2AE"], "from": [0.3, 0.1], "to": [0.75, 1]]],
    ])
    // Shine on the egg.
    s.ellipse(parent: body, x: 318, y: 290, width: 60, height: 100, props: ["fills": ["#FFFFFF"], "opacity": 0.7])
    // Front of the nest: a bowl whose upper edge dips in front of the egg.
    s.vector("Nido davanti", path: "M 96 540 C 200 604 624 604 728 540 C 712 704 576 772 412 772 C 248 772 112 704 96 540 Z",
             parent: body, props: [
                "fills": [["type": "linearGradient", "stops": ["#DDA65C", "#9C6129"], "from": [0.5, 0], "to": [0.5, 1]]],
             ])
    // Woven strands and two twigs at the rim.
    let strands: [(String, String, Double)] = [
        ("M 132 604 C 270 700 540 712 690 598", "#F6D497", 16),
        ("M 176 676 C 320 748 520 748 652 666", "#F6D497", 14),
        ("M 128 572 C 250 650 430 700 560 690", "#7E4B1F", 12),
        ("M 250 736 C 380 650 560 630 712 576", "#7E4B1F", 12),
        ("M 100 544 L 52 506", "#B87A38", 18),
        ("M 724 544 L 774 500", "#B87A38", 18),
    ]
    for (index, (path, color, weight)) in strands.enumerated() {
        let strand = s.vector("Filo \(index + 1)", path: path, parent: body, props: ["fills": [Any]()])
        s.step("stroke.add", ["ids": [strand]])
        s.set(strand, ["strokes": [color], "strokeWeight": weight, "strokeCap": "round", "strokeAlign": "center"])
    }
    return s
}
