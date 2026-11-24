#include "text_source.hpp"
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <ImageIO/ImageIO.h>
#include <algorithm>
#include <cmath>
#include <memory>
#include <stdexcept>
#include <vector>

namespace vj {
namespace {
template<class T> struct Release{void operator()(T p)const{if(p)CFRelease(p);}};
template<class T> using Owned=std::unique_ptr<std::remove_pointer_t<T>,Release<T>>;
template<class T> Owned<T> own(T p){return Owned<T>(p);}
Owned<CTLineRef> lineFor(const std::string& content,CTFontRef font){
    auto string=own(CFStringCreateWithBytes(kCFAllocatorDefault,reinterpret_cast<const UInt8*>(content.data()),content.size(),kCFStringEncodingUTF8,false));
    if(!string)throw std::invalid_argument("Text must be valid UTF-8");
    const void* keys[]={kCTFontAttributeName,kCTForegroundColorFromContextAttributeName};const void* values[]={font,kCFBooleanTrue};
    auto attributes=own(CFDictionaryCreate(kCFAllocatorDefault,keys,values,2,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks));
    auto attributed=own(CFAttributedStringCreate(kCFAllocatorDefault,string.get(),attributes.get()));
    auto line=own(CTLineCreateWithAttributedString(attributed.get()));if(!line)throw std::runtime_error("Unable to lay out text");return line;
}
struct Color {double r,g,b,a;};
Color color(const nlohmann::json& params,const char* key){const auto value=params.at(key).get<std::string>();const auto rgb=std::stoul(value.substr(1),nullptr,16);return {((rgb>>16)&255)/255.,((rgb>>8)&255)/255.,(rgb&255)/255.,params.at(std::string(key)+"_opacity").get<double>()};}
void fill(CGContextRef context,Color c){CGContextSetRGBFillColor(context,c.r,c.g,c.b,c.a);}
void stroke(CGContextRef context,Color c){CGContextSetRGBStrokeColor(context,c.r,c.g,c.b,c.a);}
void drawText(const std::filesystem::path& destination,const std::filesystem::path& fontFile,int width,int height,const nlohmann::json& params){
    auto fontURL=own(CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault,reinterpret_cast<const UInt8*>(fontFile.c_str()),fontFile.string().size(),false));
    auto provider=own(CGDataProviderCreateWithURL(fontURL.get()));
    auto graphicsFont=own(provider?CGFontCreateWithDataProvider(provider.get()):nullptr);
    if(!graphicsFont)throw std::runtime_error("Unable to load bundled font");
    auto probeFont=own(CTFontCreateWithGraphicsFont(graphicsFont.get(),100,nullptr,nullptr));
    auto probe=lineFor("Ag",probeFont.get());const auto probeBounds=CTLineGetBoundsWithOptions(probe.get(),kCTLineBoundsUseGlyphPathBounds);
    const double size=std::max(1.,std::round(params.at("size").get<double>()*height*100/std::max(1.,probeBounds.size.height)));
    auto font=own(CTFontCreateWithGraphicsFont(graphicsFont.get(),size,nullptr,nullptr));
    const double weight=std::max(0.,std::round((params.at("weight").get<double>()-2)*height/1080));
    const double outline=std::max(0.,std::round(params.at("outline_width").get<double>()*height/540));
    const double pad=weight+outline+2,slant=params.at("italic").get<bool>()?.22:0.;
    auto content=params.at("content").get<std::string>();
    for(size_t p=0;(p=content.find("\\n",p))!=std::string::npos;++p)content.replace(p,2,"\n");
    struct Line {Owned<CTLineRef> text;CGRect bounds;double width,height;bool blank;};std::vector<Line> lines;
    size_t start=0;double totalHeight=0;
    while(start<=content.size()){
        const auto end=content.find('\n',start);const auto value=content.substr(start,end==std::string::npos?std::string::npos:end-start);
        auto line=lineFor(value.empty()?"Ag":value,font.get());auto bounds=CTLineGetBoundsWithOptions(line.get(),kCTLineBoundsUseGlyphPathBounds);
        if(CGRectIsNull(bounds)||CGRectIsInfinite(bounds))bounds=CGRectMake(0,0,0,size);
        const double advance=CTLineGetTypographicBounds(line.get(),nullptr,nullptr,nullptr);
        bounds.size.width=std::max(bounds.size.width,advance);
        const double lineHeight=std::min(8192.,std::max(1.,std::ceil(bounds.size.height))+2*pad);
        const double lineWidth=std::min(16384.,std::max(1.,std::ceil(bounds.size.width))+2*pad)+std::floor(lineHeight*slant)+(slant?1:0);
        totalHeight+=lineHeight;lines.push_back({std::move(line),bounds,lineWidth,lineHeight,value.empty()});
        if(end==std::string::npos)break;start=end+1;
    }
    const double gap=std::max(1.,std::round(params.at("size").get<double>()*height*.25));totalHeight+=gap*(lines.size()-1);
    std::vector<unsigned char> pixels(static_cast<size_t>(width)*height*4,0);
    auto space=own(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
    auto context=own(CGBitmapContextCreate(pixels.data(),width,height,8,static_cast<size_t>(width)*4,space.get(),static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedLast)|kCGBitmapByteOrder32Big));
    if(!context)throw std::runtime_error("Unable to create text raster context");
    CGContextSetShouldAntialias(context.get(),true);CGContextSetShouldSmoothFonts(context.get(),false);CGContextSetLineJoin(context.get(),kCGLineJoinRound);
    fill(context.get(),color(params,"background"));CGContextFillRect(context.get(),CGRectMake(0,0,width,height));
    const auto textColor=color(params,"color"),outlineColor=color(params,"outline");
    double top=std::round(params.at("y").get<double>()*height-totalHeight/2);const double anchor=params.at("x").get<double>()*width;const std::string align=params.at("align");
    for(const auto& line:lines){
        const double left=std::round(align=="left"?anchor:(align=="right"?anchor-line.width:anchor-line.width/2));
        if(!line.blank){
            CGContextSaveGState(context.get());
            const double baseline=height-top-pad-CGRectGetMaxY(line.bounds);
            CGContextTranslateCTM(context.get(),left+pad-line.bounds.origin.x-slant*line.bounds.origin.y,baseline);
            CGContextConcatCTM(context.get(),CGAffineTransformMake(1,0,slant,1,0,0));CGContextSetTextMatrix(context.get(),CGAffineTransformIdentity);
            if(outline>0){fill(context.get(),textColor);stroke(context.get(),outlineColor);CGContextSetLineWidth(context.get(),2*(weight+outline));CGContextSetTextDrawingMode(context.get(),kCGTextFillStroke);CGContextSetTextPosition(context.get(),0,0);CTLineDraw(line.text.get(),context.get());}
            fill(context.get(),textColor);stroke(context.get(),textColor);CGContextSetLineWidth(context.get(),2*weight);CGContextSetTextDrawingMode(context.get(),weight>0?kCGTextFillStroke:kCGTextFill);CGContextSetTextPosition(context.get(),0,0);CTLineDraw(line.text.get(),context.get());
            CGContextRestoreGState(context.get());
        }
        top+=line.height+gap;
    }
    auto image=own(CGBitmapContextCreateImage(context.get()));
    auto outputURL=own(CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault,reinterpret_cast<const UInt8*>(destination.c_str()),destination.string().size(),false));
    auto output=own(CGImageDestinationCreateWithURL(outputURL.get(),CFSTR("public.png"),1,nullptr));
    if(!image||!output)throw std::runtime_error("Unable to encode text PNG");
    CGImageDestinationAddImage(output.get(),image.get(),nullptr);if(!CGImageDestinationFinalize(output.get()))throw std::runtime_error("Unable to write text PNG");
}
}
void installMacTextRasterizer(){installTextRasterizer(drawText,"coretext-bundled-rgba-v1");}
}
