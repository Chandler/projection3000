#include "vector_catalog.hpp"
#include "text_source.hpp"
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <algorithm>
#include <cmath>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
namespace vj {
namespace {
template<class T> struct Release{void operator()(T p)const{if(p)CFRelease(p);}};
template<class T> using Owned=std::unique_ptr<std::remove_pointer_t<T>,Release<T>>;
template<class T> Owned<T> own(T p){return Owned<T>(p);}
using Point=CGPoint;
Point midpoint(Point a,Point b){return {(a.x+b.x)/2,(a.y+b.y)/2};}
double distance(Point p,Point a,Point b){const double dx=b.x-a.x,dy=b.y-a.y,length=std::hypot(dx,dy);return length<1e-9?std::hypot(p.x-a.x,p.y-a.y):std::abs(dy*p.x-dx*p.y+b.x*a.y-b.y*a.x)/length;}
void quadratic(std::vector<Point>& points,Point a,Point b,Point c,double tolerance,int depth=0){if(depth>=12||distance(b,a,c)<=tolerance){points.push_back(c);return;}const auto ab=midpoint(a,b),bc=midpoint(b,c),center=midpoint(ab,bc);quadratic(points,a,ab,center,tolerance,depth+1);quadratic(points,center,bc,c,tolerance,depth+1);}
void cubic(std::vector<Point>& points,Point a,Point b,Point c,Point d,double tolerance,int depth=0){if(depth>=12||std::max(distance(b,a,d),distance(c,a,d))<=tolerance){points.push_back(d);return;}const auto ab=midpoint(a,b),bc=midpoint(b,c),cd=midpoint(c,d),abc=midpoint(ab,bc),bcd=midpoint(bc,cd),center=midpoint(abc,bcd);cubic(points,a,ab,abc,center,tolerance,depth+1);cubic(points,center,bcd,cd,d,tolerance,depth+1);}
struct Paths {std::vector<std::vector<Point>> contours;double tolerance;};
void element(void* opaque,const CGPathElement* item){auto& out=*static_cast<Paths*>(opaque);if(item->type==kCGPathElementMoveToPoint){out.contours.push_back({item->points[0]});return;}if(out.contours.empty()||out.contours.back().empty())return;auto& points=out.contours.back();switch(item->type){case kCGPathElementAddLineToPoint:points.push_back(item->points[0]);break;case kCGPathElementAddQuadCurveToPoint:quadratic(points,points.back(),item->points[0],item->points[1],out.tolerance);break;case kCGPathElementAddCurveToPoint:cubic(points,points.back(),item->points[0],item->points[1],item->points[2],out.tolerance);break;case kCGPathElementCloseSubpath:if(points.size()>1)points.push_back(points.front());break;default:break;}}
std::vector<float> outlines(std::string content,const std::string& fontName){
    static std::mutex mutex;static std::map<std::string,std::vector<float>> cache;std::lock_guard lock(mutex);
    // Match the original 256-codepoint work bound, then expand escaped newlines.
    size_t points=0,end=0;while(end<content.size()&&points<256){const unsigned char c=content[end];const size_t count=c<128?1:(c&0xe0)==0xc0?2:(c&0xf0)==0xe0?3:4;end=std::min(content.size(),end+count);++points;}content.resize(end);
    for(size_t position=0;(position=content.find("\\n",position))!=std::string::npos;++position)content.replace(position,2,"\n");
    const std::map<std::string,std::string> files={{"Archivo Black","ArchivoBlack"},{"Bebas Neue","BebasNeue"},{"Bungee","Bungee"},{"DM Serif Display","DMSerifDisplay"},{"Lobster","Lobster"},{"Pacifico","Pacifico"},{"Permanent Marker","PermanentMarker"},{"Special Elite","SpecialElite"},{"Monoton","Monoton"},{"Press Start 2P","PressStart2P"}};
    const auto found=files.find(fontName);if(found==files.end())throw std::invalid_argument("Unknown laser text font");const auto root=defaultTextFontRoot(),file=root/(found->second+".ttf");if(root.empty()||!std::filesystem::is_regular_file(file))throw std::runtime_error("Bundled laser text font is unavailable");
    const auto key=content+"\n"+file.string()+"\n"+std::to_string(static_cast<long long>(std::filesystem::last_write_time(file).time_since_epoch().count()));if(const auto cached=cache.find(key);cached!=cache.end())return cached->second;
    auto url=own(CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault,reinterpret_cast<const UInt8*>(file.c_str()),file.string().size(),false));auto provider=own(CGDataProviderCreateWithURL(url.get()));auto graphicsFont=own(provider?CGFontCreateWithDataProvider(provider.get()):nullptr);if(!graphicsFont)throw std::runtime_error("Cannot load laser text font");auto font=own(CTFontCreateWithGraphicsFont(graphicsFont.get(),96,nullptr,nullptr));auto path=own(CGPathCreateMutable());
    size_t start=0,lineIndex=0;
    while(start<=content.size()){
        const auto end=content.find('\n',start);const auto line=content.substr(start,end==std::string::npos?std::string::npos:end-start);auto string=own(CFStringCreateWithBytes(kCFAllocatorDefault,reinterpret_cast<const UInt8*>(line.data()),line.size(),kCFStringEncodingUTF8,false));if(!string)throw std::invalid_argument("Laser text must be UTF-8");const void* keys[]={kCTFontAttributeName};const void* values[]={font.get()};auto attributes=own(CFDictionaryCreate(kCFAllocatorDefault,keys,values,1,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks));auto attributed=own(CFAttributedStringCreate(kCFAllocatorDefault,string.get(),attributes.get()));auto text=own(CTLineCreateWithAttributedString(attributed.get()));const double width=CTLineGetTypographicBounds(text.get(),nullptr,nullptr,nullptr);const auto runs=CTLineGetGlyphRuns(text.get());
        for(CFIndex r=0;r<CFArrayGetCount(runs);++r){auto run=static_cast<CTRunRef>(CFArrayGetValueAtIndex(runs,r));const auto count=CTRunGetGlyphCount(run);std::vector<CGGlyph> glyphs(count);std::vector<CGPoint> positions(count);CTRunGetGlyphs(run,CFRangeMake(0,count),glyphs.data());CTRunGetPositions(run,CFRangeMake(0,count),positions.data());auto runFont=static_cast<CTFontRef>(CFDictionaryGetValue(CTRunGetAttributes(run),kCTFontAttributeName));for(CFIndex g=0;g<count;++g){auto glyph=own(CTFontCreatePathForGlyph(runFont,glyphs[g],nullptr));if(!glyph)continue;const auto transform=CGAffineTransformMakeTranslation(positions[g].x-width/2,positions[g].y-lineIndex*120.);CGPathAddPath(path.get(),&transform,glyph.get());}}
        if(end==std::string::npos)break;start=end+1;++lineIndex;
    }
    const auto bounds=CGPathGetPathBoundingBox(path.get());std::vector<float> result;
    if(!CGRectIsNull(bounds)&&!CGRectIsEmpty(bounds)){
        double tolerance=.35;Paths paths;
        for(int attempt=0;attempt<20;++attempt){paths=Paths{{},tolerance};CGPathApply(path.get(),&paths,element);size_t count=0;for(const auto& contour:paths.contours)if(contour.size()>=3)count+=contour.size();if(count<=10000)break;tolerance*=1.5;if(attempt==19)throw std::runtime_error("Laser text outline limit exceeded");}
        for(const auto& contour:paths.contours){if(contour.size()<3)continue;for(size_t i=0;i<contour.size();++i){result.push_back(i==0?2:3);result.push_back((contour[i].x-CGRectGetMidX(bounds))/96);result.push_back((CGRectGetMidY(bounds)-contour[i].y)/96);}}
    }
    if(cache.size()>=64)cache.erase(cache.begin());cache[key]=result;return result;
}
}
void installMacVectorTextOutliner(){installVectorTextOutliner(outlines);}
}
