#include "meta_mapping.hpp"
#include "api_error.hpp"
#include "collection_rendering.hpp"
#include <map>
#include <boost/uuid/random_generator.hpp>
#include <boost/uuid/uuid_io.hpp>
#include <algorithm>
#include <cmath>
#include <set>
namespace vj {
namespace {
using J=nlohmann::json;
void require(bool yes,const char* message){if(!yes)throw ApiError(400,message);}
J empty(){return {{"version",1},{"revision",0},{"placements",J::object()},{"graphs",J::array()}};}
std::string key(const J& m){return m.value("kind",std::string{})=="surface"?"surface:"+m.value("projector",std::string{})+":"+m.value("id",std::string{}):"led:"+m.value("id",std::string{});}
std::set<std::string> members(const J& d,bool enabledOnly=false){std::set<std::string> ids;for(auto it=d.at("mappings").begin();it!=d.at("mappings").end();++it)for(const auto& r:it.value().at("project").value("rects",J::array()))ids.insert("surface:"+it.key()+":"+r.at("id").get<std::string>());for(const auto& f:d.value("controls",J::object()).value("fixtures",J::array()))if(f.value("kind",std::string{})=="wled"&&(!enabledOnly||f.value("enabled",false)))ids.insert("led:"+f.at("id").get<std::string>());return ids;}
J cleaned(const J& d){J m=d.value("metaMapping",empty());auto ids=members(d);for(auto& g:m["graphs"]){auto& a=g["members"];a.erase(std::remove_if(a.begin(),a.end(),[&](const J& v){return !ids.contains(key(v));}),a.end());}return m;}
void number(const J& o,const char* k,double lo,double hi){require(o.contains(k)&&o[k].is_number(),"Expected a number");double v=o[k];require(std::isfinite(v)&&v>=lo&&v<=hi,"Number outside allowed range");}

J validatedMembers(const J& d,const J& values){
 require(values.is_array()&&values.size()<=2048,"Expected at most 2048 members");auto valid=members(d,true);std::set<std::string> seen;J result=J::array();
 for(const auto& v:values){require(v.is_object()&&(v.value("kind",std::string{})=="surface"||v.value("kind",std::string{})=="led"),"Expected surface or LED member");require(valid.contains(key(v)),"Surface missing or LED disabled");require(seen.insert(key(v)).second,"Duplicate graph member");J m={{"kind",v["kind"]},{"id",v.at("id")}};if(v["kind"]=="surface")m["projector"]=v.at("projector");result.push_back(m);}return result;
}
void patchGraph(const J& d,J& graph,const J& p){
 require(p.is_object(),"Expected graph patch");
 for(auto f=p.begin();f!=p.end();++f){const auto k=f.key();require(std::set<std::string>{"name","out","muted","opacity","blend","traversal","topology","members"}.contains(k),"Unknown graph property");
 if(k=="name")require(f->is_string()&&!f->get<std::string>().empty()&&f->get<std::string>().size()<=160,"Name needs 1..160 characters");
 if(k=="out"){require(f->is_string(),"Out must be a string");bool valid=*f=="none";for(int n=1;n<=20;++n)valid|=*f=="out"+std::to_string(n);require(valid,"Unknown Out");}
 if(k=="muted")require(f->is_boolean(),"Muted must be boolean");if(k=="opacity")number(p,"opacity",0,1);
 if(k=="blend")require(*f=="over"||*f=="add"||*f=="screen"||*f=="replace","Unknown blend mode");
 if(k=="traversal")require(*f=="once"||*f=="loop"||*f=="wander","Unknown traversal");
 if(k=="topology")require(*f=="ordered"||*f=="complete","Unknown topology");
 graph[k]=k=="members"?validatedMembers(d,*f):*f;
 }
}
J populateMembers(const J& d,const J& options){
 require(options.is_object(),"Expected populate options");for(auto i=options.begin();i!=options.end();++i)require(std::set<std::string>{"projectors","includeLEDs","includeOverlays"}.contains(i.key()),"Unknown populate option");
 for(const char* k:{"includeLEDs","includeOverlays"})if(options.contains(k))require(options[k].is_boolean(),"Expected boolean populate option");
 auto selected=options.value("projectors",J::array());require(selected.is_array(),"Expected projector array");for(const auto& id:selected)require(id.is_string()&&d["mappings"].contains(id.get<std::string>()),"Unknown projector");
 auto hidden=d.value("metaMapping",empty()).value("hiddenDestinations",J::array());J values=J::array();
 for(auto it=d.at("mappings").begin();it!=d.at("mappings").end();++it){
 if(!selected.empty()&&std::find(selected.begin(),selected.end(),J(it.key()))==selected.end())continue;
 if(selected.empty()&&std::find(hidden.begin(),hidden.end(),J("projector:"+it.key()))!=hidden.end())continue;
 for(const auto& r:it.value().at("project").value("rects",J::array()))if(options.value("includeOverlays",false)||r.value("kind",std::string{})!="overlay")values.push_back({{"kind","surface"},{"projector",it.key()},{"id",r.at("id")}});
 }
 if(options.value("includeLEDs",false))for(const auto& f:d.value("controls",J::object()).value("fixtures",J::array()))if(f.value("kind",std::string{})=="wled"&&f.value("enabled",false))values.push_back({{"kind","led"},{"id",f.at("id")}});
 return validatedMembers(d,values);
}
}
void reconcileMetaMapping(J& d){if(!d.contains("metaMapping"))return;auto m=cleaned(d);if(m!=d["metaMapping"]){m["revision"]=m.value("revision",0ULL)+1;d["metaMapping"]=std::move(m);}}
J metaMappingSnapshot(const J& d){auto m=cleaned(d);m["playbackAvailable"]=true;m["playbackTypes"]={"patch_collection"};m["spatialParticlesAvailable"]=true;m["graphTopologies"]={"ordered","complete"};m["graphActions"]={"create","set","populate","delete","moveGraph","toggleMember","moveMember","removeMember","reverse"};m["particleGeometry"]={{"boxes","worldCorners"},{"freeSurfaces","projectedEstimate"},{"leds","normalizedStrip"}};
 J destinations=J::array();int i=0;
 for(auto it=d.at("mappings").begin();it!=d.at("mappings").end();++it){std::string id="projector:"+it.key();J p={{"x",40.+i*680.},{"y",60.},{"width",640.},{"height",360.}};if(m["placements"].contains(id))p=m["placements"][id];destinations.push_back({{"id",id},{"kind","projector"},{"projector",it.key()},{"name","Projector "+it.key()},{"placement",p}});++i;}
 int l=0;for(const auto& f:d.value("controls",J::object()).value("fixtures",J::array()))if(f.value("kind",std::string{})=="wled"&&f.value("enabled",false)){std::string id="led:"+f.at("id").get<std::string>();J p={{"x",40.+l*260.},{"y",500.},{"width",220.},{"height",140.}};if(m["placements"].contains(id))p=m["placements"][id];destinations.push_back({{"id",id},{"kind","led"},{"fixture",f["id"]},{"name",f.value("label",f["id"])},{"count",f.value("count",0)},{"placement",p}});++l;}
 m["availableDestinations"]=destinations;
 auto hidden=m.value("hiddenDestinations",J::array());destinations.erase(std::remove_if(destinations.begin(),destinations.end(),[&](const J& v){return std::find(hidden.begin(),hidden.end(),v["id"])!=hidden.end();}),destinations.end());
 m["destinations"]=destinations;m["history"]={{"canUndo",!d.value("metaMappingUndo",J::array()).empty()},{"canRedo",!d.value("metaMappingRedo",J::array()).empty()}};return m;}
J metaMappingCommand(J& d,const J& c){require(c.is_object(),"Expected command object");auto m=cleaned(d),before=m;auto action=c.value("action",std::string{});if(c.contains("metaRevision")&&c["metaRevision"]!=m["revision"])throw ApiError(409,"Meta Mapping changed; retry your edit");
 if(action=="undo"||action=="redo"){const auto from=action=="undo"?"metaMappingUndo":"metaMappingRedo",to=action=="undo"?"metaMappingRedo":"metaMappingUndo";if(d.value(from,J::array()).empty())return metaMappingSnapshot(d);if(!d.contains(to))d[to]=J::array();d[to].push_back(before);m=d[from].back();d[from].erase(d[from].end()-1);m["revision"]=before.value("revision",0ULL)+1;d["metaMapping"]=m;reconcileMetaMapping(d);return metaMappingSnapshot(d);}
 if(action=="create"){require(m["graphs"].size()<128,"Maximum 128 graphs");std::string id="graph-"+boost::uuids::to_string(boost::uuids::random_generator()());
 J graph={{"id",id},{"name","Graph "+std::to_string(m["graphs"].size()+1)},{"members",J::array()},{"out","none"},{"muted",false},{"opacity",1.},{"blend","over"},{"traversal","loop"},{"topology","ordered"}};
 patchGraph(d,graph,c.value("patch",J::object()));if(c.contains("populate")){require(!c.value("patch",J::object()).contains("members"),"Choose members or populate");graph["members"]=populateMembers(d,c["populate"]);}m["graphs"].insert(m["graphs"].begin(),graph);}

 else if(action=="visibility"){auto id=c.at("id").get<std::string>();require(c.contains("visible")&&c["visible"].is_boolean(),"Expected visible boolean");auto available=metaMappingSnapshot(d)["availableDestinations"];bool found=false;for(const auto& dest:available)if(dest["id"]==id)found=true;require(found,"Unknown or disabled destination");if(!m.contains("hiddenDestinations"))m["hiddenDestinations"]=J::array();auto& hidden=m["hiddenDestinations"];auto it=std::find(hidden.begin(),hidden.end(),J(id));if(c["visible"].get<bool>()){if(it!=hidden.end())hidden.erase(it);}else if(it==hidden.end())hidden.push_back(id);}
 else if(action=="placement"){auto id=c.at("id").get<std::string>();bool exists=false;auto destinations=metaMappingSnapshot(d)["destinations"];for(const auto& dest:destinations)if(dest["id"]==id)exists=true;require(exists,"Unknown or disabled destination");auto p=c.at("placement");require(p.is_object()&&(p.size()==4||(p.size()==5&&p.contains("rotation"))),"Placement needs x, y, width, height and optional rotation");number(p,"x",-100000,100000);number(p,"y",-100000,100000);number(p,"width",20,10000);number(p,"height",20,10000);if(p.contains("rotation"))number(p,"rotation",-36000,36000);else p["rotation"]=m["placements"].value(id,J::object()).value("rotation",0.);p["rotation"]=std::fmod(p["rotation"].get<double>(),360.);m["placements"][id]=p;}
 else {auto id=c.at("id").get<std::string>();auto& graphs=m["graphs"];auto it=std::find_if(graphs.begin(),graphs.end(),[&](const J& g){return g["id"]==id;});require(it!=graphs.end(),"Unknown graph");auto index=it-graphs.begin();
  if(action=="delete")graphs.erase(it);
  else if(action=="moveGraph"){require(c.at("index").is_number_integer(),"Expected graph index");int target=c["index"];require(target>=0&&target<int(graphs.size()),"Graph index outside range");auto value=*it;graphs.erase(it);graphs.insert(graphs.begin()+target,value);}
  else if(action=="set")patchGraph(d,*it,c.at("patch"));
  else if(action=="populate")(*it)["members"]=populateMembers(d,c.value("populate",J::object()));
  else if(action=="toggleMember"){auto v=c.at("member");require(v.is_object()&&(v.value("kind",std::string{})=="surface"||v.value("kind",std::string{})=="led"),"Expected surface or LED member");require(members(d,true).contains(key(v)),"Surface missing or LED disabled");J member={{"kind",v["kind"]},{"id",v.at("id")}};if(v["kind"]=="surface")member["projector"]=v.at("projector");auto& a=(*it)["members"];auto found=std::find_if(a.begin(),a.end(),[&](const J& x){return key(x)==key(v);});if(found!=a.end())a.erase(found);else{require(a.size()<2048,"Maximum 2048 members");a.push_back(member);}}
  else if(action=="moveMember"||action=="removeMember"){auto& a=(*it)["members"];require(c.at("index").is_number_integer(),"Expected member index");int from=c["index"];require(from>=0&&from<int(a.size()),"Member index outside range");auto value=a[from];if(action=="removeMember")a.erase(a.begin()+from);else{require(c.at("to").is_number_integer(),"Expected destination index");int to=c["to"];require(to>=0&&to<int(a.size()),"Member index outside range");a.erase(a.begin()+from);a.insert(a.begin()+to,value);}}
  else if(action=="reverse")std::reverse((*it)["members"].begin(),(*it)["members"].end());
  else throw ApiError(400,"Unknown Meta Mapping action");(void)index;
 }
 if(m!=before){if(!d.contains("metaMappingUndo"))d["metaMappingUndo"]=J::array();auto& undo=d["metaMappingUndo"];undo.push_back(before);if(undo.size()>40)undo.erase(undo.begin());d["metaMappingRedo"]=J::array();m["revision"]=before.value("revision",0ULL)+1;d["metaMapping"]=std::move(m);}return metaMappingSnapshot(d);
}
}

namespace vj {
void appendMetaMappingRendering(nlohmann::json& snapshot) {
 using J=nlohmann::json;
 for(auto& mapping:snapshot["mappings"]){
  auto& rects=mapping["project"]["renderRects"];rects.erase(std::remove_if(rects.begin(),rects.end(),[](const J& r){return r.value("id",std::string{}).starts_with("meta-graph-");}),rects.end());
  auto& contexts=mapping["collectionContexts"];for(auto i=contexts.begin();i!=contexts.end();)if(i.key().starts_with("meta-graph-"))i=contexts.erase(i);else ++i;
 }
 auto& meta=snapshot["metaMapping"];meta["resolvedGraphs"]=J::array();
 const auto& grid=snapshot["state"]["grid"];
 std::map<std::string,J> placements;
 for(const auto& d:meta.value("availableDestinations",J::array()))placements[d["id"]]=d["placement"];
 // List order is layer order: the first graph is visually on top.
 // Index authored geometry once. Copying every collection per member makes
 // large graphs quadratic even when their output is unassigned.
 std::map<std::string,std::map<std::string,const J*>> rectLookup,faceLookup;
 for(auto it=snapshot["mappings"].begin();it!=snapshot["mappings"].end();++it){
  const auto& project=it.value()["project"];
  for(const auto& r:project["rects"])rectLookup[it.key()][r["id"].get<std::string>()]=&r;
  if(project.contains("collections"))for(const auto& c:project["collections"])for(const auto& f:c["faces"])faceLookup[it.key()][f["rectId"].get<std::string>()]=&f;
 }
 const auto& graphs=meta["graphs"];
 for(auto it=graphs.rbegin();it!=graphs.rend();++it){const auto& g=*it;
  const std::string id=g["id"],out=g.value("out",std::string("none")),bus=out=="out1"?"program":out;
  J resolved={{"id",id},{"out",out},{"members",J::array()},{"edges",J::array()},{"traversal",g.value("traversal",std::string("loop"))},{"blend",g.value("blend",std::string("over"))},{"opacity",g.value("opacity",1.)}};
  bool active=false;
  if(grid["running"].value(bus,false))for(const char* bank:{"selections","selections_b"}){
   auto selected=grid[bank].value(bus,J::object());
   for(const auto& row:grid["rows"]){std::string rid=row["id"];if(!row.value("enabled",true)||!selected.contains(rid))continue;auto col=selected[rid].get<std::string>();if(row["clips"].contains(col)){const auto& clip=row["clips"][col];active|=clip.value("gen",std::string{})=="patch_collection"&&clip.value("opacity",1.)>0;}}
  }
  resolved["status"]=g.value("muted",false)?"muted":out=="none"?"unassigned":active?"playing":"waitingForCollection";
  J faceIds=J::array(),centers=J::array(),charts=J::array();std::map<std::string,J> rects,faces,indices;
  int index=0;for(const auto& member:g["members"]){const bool led=member["kind"]=="led";std::string mid=led?"":member["projector"].get<std::string>(),rid=member["id"],dest=led?"led:"+rid:"projector:"+mid;
   if(!placements.contains(dest))continue;
   const auto& p=placements[dest];double x=.5,y=.5;J rect;
   if(!led){if(!rectLookup[mid].contains(rid))continue;rect=*rectLookup[mid][rid];if(rect.is_null()||rect["corners"].size()!=4)continue;
    x=0;y=0;for(const auto& v:rect["corners"]){x+=v[0].get<double>()/4;y+=v[1].get<double>()/4;}
   }
   double w=p.value("width",640.),h=p.value("height",360.),angle=p.value("rotation",0.)*3.141592653589793/180.,dx=(x-.5)*w,dy=(y-.5)*h;
   J center=J::array({p.value("x",0.)+w*.5+dx*std::cos(angle)-dy*std::sin(angle),p.value("y",0.)+h*.5+dx*std::sin(angle)+dy*std::cos(angle)});
   J chart={{"index",index},{"metricSource","normalizedStrip"},{"aspect",w/h},{"valid",false}};
   if(!led){J face={{"planeCorners",rect["corners"]}};if(faceLookup[mid].contains(rid))face=*faceLookup[mid][rid];
    double outputAspect=16./9.;for(const auto& display:snapshot.value("projectors",J::object()).value("displays",J::array()))if(std::to_string(display.value("id",0))==mid&&display.value("height",0)>0)outputAspect=double(display.value("width",1920))/display["height"].get<double>();
    int outputRotation=snapshot["mappings"][mid]["project"].value("output",J::object()).value("rotation",0);bool quarterTurn=((outputRotation%180+180)%180)==90;
    // Layout coordinates steer the graph; final output pixels measure free-surface circles.
    chart=particleFaceChart(face,rect,w/h,quarterTurn?1/outputAspect:outputAspect);chart["index"]=index;chart["outputRotation"]=outputRotation;
    if(chart.value("valid",false)){auto basis=chart["basis"];for(auto& v:basis){double x=v[0].get<double>()*h,y=v[1].get<double>()*h;v={x*std::cos(angle)-y*std::sin(angle),x*std::sin(angle)+y*std::cos(angle)};}chart["basis"]=basis;}
   }
   charts.push_back(chart);
   auto m=member;m["index"]=index;m["center"]=center;m["particleGeometry"]=chart;resolved["members"].push_back(m);faceIds.push_back(dest+":"+rid);centers.push_back(center);
   if(!led){if(!rects.contains(mid)){rects[mid]=J::array();faces[mid]=J::array();indices[mid]=J::array();}rects[mid].push_back(rect);faces[mid].push_back({{"id",dest+":"+rid},{"rectId",rid},{"planeCorners",rect["corners"]}});indices[mid].push_back(index);}
   ++index;
  }
  const bool complete=g.value("topology",std::string("ordered"))=="complete";resolved["topology"]=complete?"complete":"ordered";
  resolved["implicitEdges"]=complete&&index>64;resolved["directed"]=!complete;
  if(complete){resolved["edgeCount"]=index*(index-1)/2;if(index<=64)for(int a=0;a<index;a++)for(int b=a+1;b<index;b++)resolved["edges"].push_back({a,b});}
  else {for(int i=1;i<index;i++)resolved["edges"].push_back({i-1,i});if(index>1&&g.value("traversal",std::string("loop"))=="loop")resolved["edges"].push_back({index-1,0});resolved["edgeCount"]=resolved["edges"].size();}
  resolved["active"]=active&&!g.value("muted",false)&&g.value("opacity",1.)>0&&index>0;
  meta["resolvedGraphs"].push_back(resolved);
  if(!resolved["active"].get<bool>())continue;
  for(const auto& [mid,members]:rects){auto geometry=collectionGeometry({{"faces",faces[mid]},{"rects",members},{"kind","planar"}});
   auto localIndices=geometry["cardFaceIndices"];for(auto& n:localIndices)n=indices[mid][n.get<int>()];
   geometry.update({{"cardFaceIndices",localIndices},{"faceIds",faceIds},{"centers",centers},{"particleFaces",charts},{"edges",resolved["edges"]},{"metaGraph",id},{"graphTopology",resolved["topology"]},{"graphTraversal",resolved["traversal"]},{"graphOpacity",resolved["opacity"]},{"graphReplace",resolved["blend"]=="replace"}});
   const std::string key="meta-"+id+"-"+mid;auto& mapping=snapshot["mappings"][mid];mapping["collectionContexts"][key]={{"source",out},{"geometry",geometry}};
   J masks=J::array();for(const auto& r:members)masks.push_back({{"corners",r["corners"]},{"cornerRadius",r.value("cornerRadius",0.)},{"curvature",r.value("curvature",J())}});
   // Meta graphs layer over ordinary surfaces, beneath explicit Mapper overlays.
   // Inserting before the first overlay preserves both graph and overlay order.
   auto& renderRects=mapping["project"]["renderRects"];
   auto overlay=std::find_if(renderRects.begin(),renderRects.end(),[](const J& rect){return rect.value("kind",std::string{})=="overlay";});
   renderRects.insert(overlay,J{{"id",key},{"name",g["name"]},{"source",out},{"nativeBus",key},{"mode","live"},{"blend",resolved["blend"]=="over"||resolved["blend"]=="replace"?J("premultiplied"):resolved["blend"]},{"fit","stretch"},{"corners",{{0,0},{1,0},{1,1},{0,1}}},{"uvs",{{0,1},{1,1},{1,0},{0,0}}},{"maskSurfaces",masks}});
  }
 }
}
}
