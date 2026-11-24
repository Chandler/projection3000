import Foundation
import PatchCore

final class GraphTests {
    func testRetiredInkTwoLoadsAsGraphInkFlow() throws {
        let kinds = try JSONDecoder().decode([NodeKind].self, from: Data(#"["graphInkFlow2","graphInkFlow"]"#.utf8))
        checkEqual(kinds, [NodeKind.graphInkFlow, .graphInkFlow])
        checkEqual(try JSONDecoder().decode([NodeKind].self, from: Data(#"["lightField"]"#.utf8)), [NodeKind.streakGlow])
        checkEqual(NodeKind.streakGlow.parameters.first { $0.key == "function" }?.initial, 0)
        checkThrows(try JSONDecoder().decode([NodeKind].self, from: Data(#"["notAKind"]"#.utf8)))
    }
    func testFaceCoordinatesAndPorts() throws {
        var g = Graph(); let source = Node(kind:.webcam), detector = Node(kind:.faceDetect), boxes = Node(kind:.faceBoxes)
        g.nodes = [boxes,detector,source]
        try g.connect(source.id,to:detector.id); try g.connect(source.id,to:boxes.id); try g.connect(detector.id,to:boxes.id,input:1)
        checkEqual(try g.orderedNodes().map(\.kind),[.webcam,.faceDetect,.faceBoxes])
        checkThrows(try g.connect(detector.id,to:boxes.id,input:0))
        checkThrows(try g.connect(source.id,to:boxes.id,input:1))
        checkThrows(try g.connect(boxes.id,to:detector.id))
        checkEqual(try JSONDecoder().decode(Graph.self,from:JSONEncoder().encode(g)),g)
        let bounds = FaceBounds.fromVision(x:0.25,y:0.25,width:0.5,height:0.25)
        checkEqual(bounds.y,0.5)
        checkEqual(bounds.landmark(x:0.5,y:1),FacePoint(x:0.5,y:0.5))
        checkEqual(bounds.landmark(x:0,y:0),FacePoint(x:0.25,y:0.75))
    }
    func testTypedGeometryPipelineAndOrder() throws {
        let g = Graph.demo
        checkNoThrow(try g.validated())
        checkEqual(try g.orderedNodes().map(\.kind),[.lorenz,.render,.crt,.window])
        checkEqual(g.nodes[0].kind.outputType,.geometry)
        checkEqual(g.nodes[1].kind.inputTypes,[.geometry])
        checkEqual(g.nodes[1].kind.outputType,.video)
    }
    func testRejectsGeometryDirectlyIntoVideoEffect() {
        var g = Graph.demo; let before = g
        checkThrows(try g.connect(g.nodes[0].id,to:g.nodes[2].id))
        checkEqual(g,before)
    }
    func testRejectsVideoIntoGeometry() {
        var g = Graph.demo
        checkThrows(try g.connect(g.nodes[2].id,to:g.nodes[1].id))
    }
    func testCycleIsRejectedAtomically() throws {
        var g = Graph(); let a = Node(kind:.crt), b = Node(kind:.color)
        g.nodes = [a,b]; try g.connect(a.id,to:b.id)
        let before = g
        checkThrows(try g.connect(b.id,to:a.id)); checkEqual(g,before)
    }
    func testReplacementMaintainsSingleInput() throws {
        var g = Graph(); let a = Node(kind:.pattern), b = Node(kind:.image), c = Node(kind:.crt)
        g.nodes = [c,a,b]; try g.connect(a.id,to:c.id); try g.connect(b.id,to:c.id)
        checkEqual(g.edges.count,1); checkEqual(g.edges[0].source,b.id)
        checkNoThrow(try g.validated())
    }
    func testBlendFanInAndFanOut() throws {
        var g = Graph(); let a = Node(kind:.pattern), b = Node(kind:.blend), c = Node(kind:.window)
        g.nodes = [c,b,a]; try g.connect(a.id,to:b.id); try g.connect(a.id,to:b.id,input:1); try g.connect(b.id,to:c.id)
        checkEqual(try g.orderedNodes().map(\.id),[a.id,b.id,c.id])
        checkThrows(try g.connect(a.id,to:b.id,input:2))
        checkThrows(try g.connect(c.id,to:b.id))
    }
    func testInsertionAndRemoval() throws {
        var g = Graph.demo; let n = Node(kind:.color); g.nodes.append(n)
        let edge = g.edges.last!
        try g.insert(n.id,on:edge.id)
        checkTrue(g.edges.contains { $0.source == edge.source && $0.target == n.id })
        checkTrue(g.edges.contains { $0.source == n.id && $0.target == edge.target })
        g.remove(n.id); checkFalse(g.edges.contains { $0.source == n.id || $0.target == n.id })
        checkNoThrow(try g.validated())
    }
    func testInsertionRejectsIncompatibleCable() {
        var g = Graph.demo; let n = Node(kind:.color); g.nodes.append(n); let before = g
        checkThrows(try g.insert(n.id,on:g.edges.first!.id)); checkEqual(g,before)
    }
    func testValidationRejectsCorruptProjects() throws {
        var g = Graph.demo; g.nodes.append(g.nodes[0]); checkThrows(try g.validated())
        g = .demo; g.edges.append(Edge(source:UUID(),target:g.nodes[2].id)); checkThrows(try g.validated())
        g = .demo; g.width = -1; checkThrows(try g.validated())
        g = .demo; g.nodes[0].position.x = .infinity; checkThrows(try g.validated())
        g = .demo; g.edges.append(Edge(source:g.nodes[2].id,target:g.nodes[3].id)); checkThrows(try g.validated())
    }
    func testParameterBounds() throws {
        var g = Graph.demo; let crt = g.nodes[2].id
        checkThrows(try g.setParameter(crt,key:"noise",value:1))
        checkThrows(try g.setParameter(crt,key:"noise",value:.nan))
        checkThrows(try g.setParameter(crt,key:"missing",value:0))
        try g.setParameter(crt,key:"noise",value:0.1); checkEqual(g.node(crt)?.value("noise"),0.1)
        let blend = Node(kind:.blend); g.nodes.append(blend)
        checkThrows(try g.setParameter(blend.id,key:"mode",value:1.5))
    }
    func testRoundtripPreservesIDsAndPaths() throws {
        var g = Graph.demo; var media = Node(kind:.video); media.file = "/tmp/A movie.mov"; g.nodes.append(media)
        let loaded = try JSONDecoder().decode(Graph.self,from:JSONEncoder().encode(g)).validated()
        checkEqual(g,loaded)
    }
    func testComponentsAndLayout() throws {
        var g = Graph.demo; let old = g
        let id = try g.makeComponent(Set([g.nodes[1].id,g.nodes[2].id]))
        let group = g.component(id)!
        checkEqual(g.ports(group,output:false).count,1)
        checkEqual(g.ports(group,output:false)[0].type,.geometry)
        checkEqual(g.ports(group,output:true).count,1)
        checkEqual(g.ports(group,output:true)[0].node,g.nodes[2].id)
        checkEqual(g.edges,old.edges); checkEqual(try g.orderedNodes().map(\.id),try old.orderedNodes().map(\.id))
        checkEqual(g,try JSONDecoder().decode(Graph.self,from:JSONEncoder().encode(g)).validated())
        try g.autoLayout(); let first = g; try g.autoLayout(); checkEqual(g,first)
        checkEqual(g.edges,old.edges)
        g.remove(id); checkEqual(g.nodes.count,2); checkEqual(g.groups.count,0); checkEqual(g.edges.count,0)
        checkNoThrow(try g.validated())
    }
    func testVideoLoopValidationAndPreviewKinds() throws {
        var g = Graph(); var v = Node(kind:.video); v.parameters["start"] = 2; v.parameters["end"] = 1; g.nodes = [v]
        checkThrows(try g.validated()); g.nodes[0].parameters["end"] = 3; checkNoThrow(try g.validated())
        checkEqual(NodeKind.audio.previewKind,.audio); checkEqual(NodeKind.lorenz.previewKind,.geometry)
        checkEqual(NodeKind.record.previewKind,.video)
    }
    func testAudioTypesAndTextRoundtrip() throws {
        var graph = Graph(); let audio = Node(kind:.audio), waveform = Node(kind:.waveform), crt = Node(kind:.crt)
        var text = Node(kind:.text); text.text = "Hello\nPatch"; text.parameters["size"] = 144
        graph.nodes = [audio,waveform,crt,text]
        try graph.connect(audio.id,to:waveform.id); try graph.connect(waveform.id,to:crt.id)
        checkThrows(try graph.connect(audio.id,to:crt.id))
        checkThrows(try graph.connect(text.id,to:waveform.id))
        checkEqual(graph,try JSONDecoder().decode(Graph.self,from:JSONEncoder().encode(graph)))
    }
    func testLorenzProducesFiniteDeterministicGeometry() throws {
        let a = try GeometryGenerator.lorenz(sigma:10,rho:28,beta:2.667,count:16000)
        let b = try GeometryGenerator.lorenz(sigma:10,rho:28,beta:2.667,count:16000)
        checkEqual(a,b); checkEqual(a.count,16000); checkEqual(a.first?.w,0); checkEqual(a.last?.w,1)
        checkTrue(a.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        checkGreater(a.map(\.x).max()!-a.map(\.x).min()!,0.5)
        checkThrows(try GeometryGenerator.lorenz(sigma:100,rho:28,beta:2,count:16000))
    }
}

func checkTrue(_ value: @autoclosure () -> Bool, file: StaticString = #file, line: UInt = #line) { if !value() { fatalError("Check failed",file:file,line:line) } }
func checkFalse(_ value: @autoclosure () -> Bool, file: StaticString = #file, line: UInt = #line) { checkTrue(!value(),file:file,line:line) }
func checkEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) { do { let a = try lhs(), b = try rhs(); if a != b { fatalError("Not equal: \(a), \(b)",file:file,line:line) } } catch { fatalError("Unexpected error: \(error)",file:file,line:line) } }
func checkGreater<T: Comparable>(_ a:T,_ b:T,file:StaticString = #file,line:UInt = #line) { checkTrue(a>b,file:file,line:line) }
func checkNoThrow<T>(_ expression: @autoclosure () throws -> T,file:StaticString = #file,line:UInt = #line) { do { _ = try expression() } catch { fatalError("Unexpected error: \(error)",file:file,line:line) } }
func checkThrows<T>(_ expression: @autoclosure () throws -> T,file:StaticString = #file,line:UInt = #line) { do { _ = try expression() } catch { return }; fatalError("Expected rejection",file:file,line:line) }
@main struct CoreChecks {
    static func main() throws {
        let suite = GraphTests()
        try suite.testRetiredInkTwoLoadsAsGraphInkFlow(); print("PASS testRetiredInkTwoLoadsAsGraphInkFlow")
        try suite.testFaceCoordinatesAndPorts(); print("PASS testFaceCoordinatesAndPorts")
        try suite.testTypedGeometryPipelineAndOrder(); print("PASS testTypedGeometryPipelineAndOrder")
        suite.testRejectsGeometryDirectlyIntoVideoEffect(); print("PASS testRejectsGeometryDirectlyIntoVideoEffect")
        suite.testRejectsVideoIntoGeometry(); print("PASS testRejectsVideoIntoGeometry")
        try suite.testCycleIsRejectedAtomically(); print("PASS testCycleIsRejectedAtomically")
        try suite.testReplacementMaintainsSingleInput(); print("PASS testReplacementMaintainsSingleInput")
        try suite.testBlendFanInAndFanOut(); print("PASS testBlendFanInAndFanOut")
        try suite.testInsertionAndRemoval(); print("PASS testInsertionAndRemoval")
        suite.testInsertionRejectsIncompatibleCable(); print("PASS testInsertionRejectsIncompatibleCable")
        try suite.testValidationRejectsCorruptProjects(); print("PASS testValidationRejectsCorruptProjects")
        try suite.testParameterBounds(); print("PASS testParameterBounds")
        try suite.testRoundtripPreservesIDsAndPaths(); print("PASS testRoundtripPreservesIDsAndPaths")
        try suite.testLorenzProducesFiniteDeterministicGeometry(); print("PASS testLorenzProducesFiniteDeterministicGeometry")
        try suite.testAudioTypesAndTextRoundtrip(); print("PASS testAudioTypesAndTextRoundtrip")
        try suite.testComponentsAndLayout(); print("PASS testComponentsAndLayout")
        try suite.testVideoLoopValidationAndPreviewKinds(); print("PASS testVideoLoopValidationAndPreviewKinds")
        print("16 core checks passed")
    }
}
