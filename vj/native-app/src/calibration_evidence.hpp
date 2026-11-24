#pragma once
#include <nlohmann/json.hpp>
#include <algorithm>
#include <array>
#include <cmath>
#include <limits>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>
namespace vj {
// Static-scene memory matching static/calibrate/rectangle-evidence.js. Tracks
// never age out: reset explicitly when the camera or scene changes.
class RectangleEvidence {
    using J=nlohmann::json;
    struct Alignment {J points;double score=std::numeric_limits<double>::infinity(),maximum=0;};
    J tracks_=J::array(),rejected_=J::array();std::uint64_t next_=1;
    static double distance(const J& a,const J& b){return std::hypot(a.at("x").get<double>()-b.at("x").get<double>(),a.at("y").get<double>()-b.at("y").get<double>());}
    static Alignment align(const J& reference,const J& points){Alignment best;for(bool reversed:{false,true})for(int shift=0;shift<4;++shift){Alignment match;match.points=J::array();match.score=0;for(int i=0;i<4;++i){const auto& p=points[(shift+(reversed?-i:i)+4)%4];match.points.push_back(p);double d=distance(p,reference[i]);match.score+=d*d/4;match.maximum=std::max(match.maximum,d);}if(match.score<best.score)best=std::move(match);}return best;}
    static J geometry(const J& points){if(!points.is_array()||points.size()!=4)throw std::invalid_argument("Rectangle evidence requires four corners");double x=0,y=0,area=0;for(int i=0;i<4;++i){double px=points[i].at("x"),py=points[i].at("y"),qx=points[(i+1)%4].at("x"),qy=points[(i+1)%4].at("y");if(!std::isfinite(px)||!std::isfinite(py))throw std::invalid_argument("Invalid rectangle evidence coordinate");x+=px/4;y+=py/4;area+=px*qy-qx*py;}return {{"points",points},{"center",{{"x",x},{"y",y}}},{"area",std::abs(area)/2}};}
    static bool matches(const J& a,const J& b){double area=a.at("area"),ratio=b.at("area").get<double>()/area;return ratio>.6&&ratio<1.6&&align(a.at("points"),b.at("points")).maximum<std::max(8.,std::sqrt(area)*.15);}
public:
    const J& tracks() const{return tracks_;}
    void reset(){tracks_=J::array();rejected_=J::array();next_=1;}
    void remove(std::size_t index){if(index>=tracks_.size())return;rejected_.push_back(tracks_[index]);tracks_.erase(tracks_.begin()+index);}
    void removeId(std::uint64_t id){for(size_t i=0;i<tracks_.size();++i)if(tracks_[i]["evidenceId"]==id){remove(i);return;}}
    void setGeometry(std::uint64_t id,const J& points){for(auto& track:tracks_)if(track["evidenceId"]==id){track.update(geometry(points));return;}}
    const J& add(const J& input,const std::string& frameKey,const std::set<std::uint64_t>& frozen={},bool explicitHint=false){
        J detections=J::array();for(const auto& raw:input){auto detection=geometry(raw.at("points"));double area=raw.value("area",detection.at("area").get<double>());if(!std::isfinite(area)||area<=0)continue;detection["area"]=area;detections.push_back(std::move(detection));}
        if(explicitHint)rejected_.erase(std::remove_if(rejected_.begin(),rejected_.end(),[&](const J& rejected){return std::any_of(detections.begin(),detections.end(),[&](const J& detection){return matches(rejected,detection);});}),rejected_.end());
        else detections.erase(std::remove_if(detections.begin(),detections.end(),[&](const J& detection){return std::any_of(rejected_.begin(),rejected_.end(),[&](const J& rejected){return matches(rejected,detection);});}),detections.end());
        struct Pair{Alignment alignment;size_t track,detection;};std::vector<Pair> pairs;
        for(size_t t=0;t<tracks_.size();++t)for(size_t d=0;d<detections.size();++d){const auto& track=tracks_[t];double ratio=detections[d]["area"].get<double>()/track["anchorArea"].get<double>();if(ratio<.72||ratio>1.38)continue;auto match=align(track["anchor"],detections[d]["points"]);double side=std::numeric_limits<double>::infinity();for(int i=0;i<4;++i)side=std::min(side,distance(track["anchor"][i],track["anchor"][(i+1)%4]));if(match.maximum<=std::max(6.,std::min(25.,side*.1)))pairs.push_back({std::move(match),t,d});}
        std::stable_sort(pairs.begin(),pairs.end(),[](const Pair& a,const Pair& b){return a.alignment.score<b.alignment.score;});std::set<size_t> usedTracks,usedDetections;
        for(const auto& pair:pairs){if(usedTracks.contains(pair.track)||usedDetections.contains(pair.detection))continue;usedTracks.insert(pair.track);usedDetections.insert(pair.detection);auto& track=tracks_[pair.track];if(track["lastFrame"]==frameKey)continue;track["seen"]=track["seen"].get<std::uint64_t>()+1;track["lastFrame"]=frameKey;if(!frozen.contains(track["evidenceId"].get<std::uint64_t>())){auto samples=track["geometrySamples"].get<std::uint64_t>()+1;track["geometrySamples"]=samples;double weight=1./samples;auto points=track["points"];for(int i=0;i<4;++i)for(auto axis:{"x","y"})points[i][axis]=points[i][axis].get<double>()+(pair.alignment.points[i][axis].get<double>()-points[i][axis].get<double>())*weight;track.update(geometry(points));}}
        for(size_t d=0;d<detections.size();++d)if(!usedDetections.contains(d)){auto track=geometry(detections[d]["points"]);track.update({{"anchor",track["points"]},{"anchorArea",detections[d]["area"]},{"seen",1},{"geometrySamples",1},{"lastFrame",frameKey},{"evidenceId",next_++}});tracks_.push_back(std::move(track));}
        return tracks_;
    }
};
}
