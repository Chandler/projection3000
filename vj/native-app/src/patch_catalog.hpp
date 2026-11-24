#pragma once
#include <nlohmann/json.hpp>
namespace vj {
inline nlohmann::json patchEffectCatalog(){
 using J=nlohmann::json;J result=J::array();
 for(const auto* type:{"video","collection","trace"}){
  bool collection=std::string(type)=="collection",trace=std::string(type)=="trace";
  J entry={{"name",std::string("patch_")+type},{"label",trace?"Patch Trace":collection?"Patch Collection":"Patch Video"},{"patchSource",true},{"parameters",J::array({{{"name","source"},{"label","Patch output"},{"kind","text"},{"default",""},{"patchSource",type}}})},{"performanceParameters",J::array()}};
  if(trace){entry["kind"]="trace";entry["collectionGeometry"]="trace";entry["defaultBlend"]="add";}
  else if(collection){entry["kind"]="collection";entry["collectionGeometry"]="patch";}
  else{entry["parameters"].push_back({{"name","fit"},{"label","Fit"},{"kind","choice"},{"choices",{"cover","contain","stretch"}},{"default","cover"}});}
  result.push_back(entry);
 }
 return result;
}
}
