import Foundation
import CoreGraphics

/// Orthogonal visibility-grid routing with clearance around visible node boxes.
public enum CableRouter {
    private struct Entry { var state: Int; var score: Double }
    public static func route(from a: CGPoint,to b: CGPoint,obstacles boxes: [CGRect]) -> [CGPoint] {
        let margin: CGFloat = 12
        let boxes = boxes.map { $0.insetBy(dx:-margin,dy:-margin) }
        let start = CGPoint(x:a.x+20,y:a.y), end = CGPoint(x:b.x-20,y:b.y)
        func inside(_ p: CGPoint) -> Bool { boxes.contains { p.x>$0.minX+0.01 && p.x<$0.maxX-0.01 && p.y>$0.minY+0.01 && p.y<$0.maxY-0.01 } }
        func clear(_ p: CGPoint,_ q: CGPoint) -> Bool {
            !boxes.contains { r in
                if abs(p.y-q.y)<0.01 { return p.y>r.minY+0.01 && p.y<r.maxY-0.01 && max(p.x,q.x)>r.minX+0.01 && min(p.x,q.x)<r.maxX-0.01 }
                return p.x>r.minX+0.01 && p.x<r.maxX-0.01 && max(p.y,q.y)>r.minY+0.01 && min(p.y,q.y)<r.maxY-0.01
            }
        }
        guard !inside(start), !inside(end) else { return [a,b] }
        let xs = Array(Set([start.x,end.x]+boxes.flatMap { [$0.minX,$0.maxX] })).sorted()
        let ys = Array(Set([start.y,end.y]+boxes.flatMap { [$0.minY,$0.maxY] })).sorted()
        let nx=xs.count, ny=ys.count
        let first=ys.firstIndex(of:start.y)!*nx+xs.firstIndex(of:start.x)!
        let last=ys.firstIndex(of:end.y)!*nx+xs.firstIndex(of:end.x)!
        func point(_ index: Int) -> CGPoint { CGPoint(x:xs[index%nx],y:ys[index/nx]) }
        func heuristic(_ index: Int) -> Double { let p=point(index); return Double(abs(p.x-end.x)+abs(p.y-end.y)) }
        // Direction is part of the search state, to penalize unnecessary bends.
        var costs=[Double](repeating:.infinity,count:nx*ny*2), previous=[Int](repeating:-1,count:nx*ny*2)
        var heap: [Entry] = []
        func push(_ entry: Entry) {
            heap.append(entry); var i=heap.count-1
            while i>0 { let parent=(i-1)/2; if heap[parent].score<=heap[i].score { break }; heap.swapAt(parent,i); i=parent }
        }
        func pop() -> Entry {
            let result=heap[0], tail=heap.removeLast()
            if !heap.isEmpty {
                heap[0]=tail; var i=0
                while i*2+1<heap.count {
                    var child=i*2+1
                    if child+1<heap.count && heap[child+1].score<heap[child].score { child+=1 }
                    if heap[i].score<=heap[child].score { break }; heap.swapAt(i,child); i=child
                }
            }
            return result
        }
        costs[first*2]=0; push(Entry(state:first*2,score:heuristic(first)))
        var finish: Int?
        while !heap.isEmpty {
            let entry=pop(), state=entry.state, index=state/2, direction=state%2
            if entry.score>costs[state]+heuristic(index)+0.01 { continue }
            if index==last { finish=state; break }
            let x=index%nx,y=index/nx,p=point(index)
            var next: [(Int,Int)] = []
            if x>0 { next.append((index-1,0)) }; if x+1<nx { next.append((index+1,0)) }
            if y>0 { next.append((index-nx,1)) }; if y+1<ny { next.append((index+nx,1)) }
            for (candidate,axis) in next {
                let q=point(candidate)
                guard clear(p,q) else { continue }
                let target=candidate*2+axis
                let cost=costs[state]+Double(abs(p.x-q.x)+abs(p.y-q.y))+(axis==direction ? 0 : 24)
                if cost<costs[target] { costs[target]=cost; previous[target]=state; push(Entry(state:target,score:cost+heuristic(candidate))) }
            }
        }
        guard var state=finish else { return [a,b] }
        var points: [CGPoint] = [b]
        while state>=0 { points.append(point(state/2)); state=previous[state] }
        points.append(a); points.reverse()
        var simplified: [CGPoint] = []
        for p in points {
            if let last=simplified.last, last.x==p.x && last.y==p.y { continue }
            if simplified.count>=2 {
                let q=simplified[simplified.count-1],r=simplified[simplified.count-2]
                if abs((q.x-r.x)*(p.y-q.y)-(q.y-r.y)*(p.x-q.x))<0.001 && (q.x-r.x)*(p.x-q.x)+(q.y-r.y)*(p.y-q.y)>=0 { simplified.removeLast() }
            }
            simplified.append(p)
        }
        return simplified
    }
}
