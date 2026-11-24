#include "text_source.hpp"
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_GLYPH_H
#include FT_STROKER_H
#include FT_OUTLINE_H
#include <hb-ft.h>
#include <png.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <map>
#include <mutex>
#include <stdexcept>
namespace vj { namespace {
using J=nlohmann::json;
void checked(FT_Error error){if(error)throw std::runtime_error("FreeType error "+std::to_string(error));}
struct Face {
 FT_Library library=nullptr;FT_Face face=nullptr;
 explicit Face(const std::filesystem::path& file){checked(FT_Init_FreeType(&library));if(auto error=FT_New_Face(library,file.c_str(),0,&face)){FT_Done_FreeType(library);library=nullptr;checked(error);}}
 ~Face(){if(face)FT_Done_Face(face);if(library)FT_Done_FreeType(library);}
 void size(unsigned pixels){checked(FT_Set_Pixel_Sizes(face,0,std::clamp(pixels,1u,8192u)));}
};
struct Glyph {unsigned id;double x,y;};
struct Line {std::vector<Glyph> glyphs;double left=0,right=0,bottom=0,top=0,advance=0;};
Line shape(Face& font,const std::string& text){Line line;hb_font_t* hb=hb_ft_font_create_referenced(font.face);hb_buffer_t* buffer=hb_buffer_create();hb_buffer_add_utf8(buffer,text.c_str(),text.size(),0,text.size());hb_buffer_guess_segment_properties(buffer);hb_shape(hb,buffer,nullptr,0);unsigned count;auto info=hb_buffer_get_glyph_infos(buffer,&count);auto positions=hb_buffer_get_glyph_positions(buffer,&count);double x=0,y=0;for(unsigned i=0;i<count;++i){if(!info[i].codepoint){hb_buffer_destroy(buffer);hb_font_destroy(hb);throw std::runtime_error("Font does not contain a requested glyph");}double gx=x+positions[i].x_offset/64.,gy=y+positions[i].y_offset/64.;line.glyphs.push_back({info[i].codepoint,gx,gy});if(!FT_Load_Glyph(font.face,info[i].codepoint,FT_LOAD_DEFAULT)){auto m=font.face->glyph->metrics;line.left=std::min(line.left,gx+m.horiBearingX/64.);line.right=std::max(line.right,gx+(m.horiBearingX+m.width)/64.);line.top=std::max(line.top,gy+m.horiBearingY/64.);line.bottom=std::min(line.bottom,gy+(m.horiBearingY-m.height)/64.);}x+=positions[i].x_advance/64.;y+=positions[i].y_advance/64.;}line.advance=x;line.right=std::max(line.right,x);hb_buffer_destroy(buffer);hb_font_destroy(hb);return line;}
std::vector<std::string> lines(std::string content){for(size_t p=0;(p=content.find("\\n",p))!=std::string::npos;++p)content.replace(p,2,"\n");std::vector<std::string> result;size_t start=0;for(;;){auto end=content.find('\n',start);result.push_back(content.substr(start,end==std::string::npos?end:end-start));if(end==std::string::npos)break;start=end+1;}return result;}
using Color=std::array<double,4>;
Color color(const J& params,const std::string& key){auto value=std::stoul(params.at(key).get<std::string>().substr(1),nullptr,16);return {double((value>>16)&255),double((value>>8)&255),double(value&255),params.at(key+"_opacity")};}
void over(std::vector<unsigned char>& pixels,int width,int height,int x,int y,Color c,double coverage){if(x<0||y<0||x>=width||y>=height)return;auto* p=&pixels[(size_t(y)*width+x)*4];double a=c[3]*coverage,old=p[3]/255.,out=a+old*(1-a);for(int i=0;i<3;++i)p[i]=out>0?std::clamp(int(std::lround((c[i]*a+p[i]*old*(1-a))/out)),0,255):0;p[3]=std::clamp(int(std::lround(out*255)),0,255);}
void bitmap(Face& font,unsigned id,int radius,double x,double baseline,double italic,Color c,std::vector<unsigned char>& pixels,int width,int height){checked(FT_Load_Glyph(font.face,id,FT_LOAD_DEFAULT));FT_Glyph glyph=nullptr;checked(FT_Get_Glyph(font.face->glyph,&glyph));if(italic){FT_Matrix transform={65536,FT_Fixed(italic*65536),0,65536};FT_Glyph_Transform(glyph,&transform,nullptr);}if(radius>0){FT_Stroker stroker;auto result=FT_Stroker_New(font.library,&stroker);if(result){FT_Done_Glyph(glyph);checked(result);}FT_Stroker_Set(stroker,radius*64,FT_STROKER_LINECAP_ROUND,FT_STROKER_LINEJOIN_ROUND,0);result=FT_Glyph_StrokeBorder(&glyph,stroker,0,1);FT_Stroker_Done(stroker);if(result){FT_Done_Glyph(glyph);checked(result);}}auto error=FT_Glyph_To_Bitmap(&glyph,FT_RENDER_MODE_NORMAL,nullptr,1);if(error){FT_Done_Glyph(glyph);checked(error);}auto b=(FT_BitmapGlyph)glyph;for(unsigned row=0;row<b->bitmap.rows;++row){auto* data=b->bitmap.buffer+(b->bitmap.pitch>=0?row:b->bitmap.rows-1-row)*std::abs(b->bitmap.pitch);for(unsigned col=0;col<b->bitmap.width;++col){double coverage=b->bitmap.pixel_mode==FT_PIXEL_MODE_MONO?((data[col/8]>>(7-col%8))&1):data[col]/255.;over(pixels,width,height,int(std::round(x))+b->left+col,int(std::round(baseline))-b->top+row,c,coverage);}}FT_Done_Glyph(glyph);}
void raster(const std::filesystem::path& destination,const std::filesystem::path& file,int width,int height,const J& params){Face font(file);font.size(100);auto probe=shape(font,"Ag");double size=std::max(1.,std::round(params.at("size").get<double>()*height*100/std::max(1.,probe.top-probe.bottom)));font.size(size);int weight=std::max(0,int(std::round((params.at("weight").get<double>()-2)*height/1080))),outline=std::max(0,int(std::round(params.at("outline_width").get<double>()*height/540)));double pad=weight+outline+2,slant=params.at("italic").get<bool>()?.22:0,gap=std::max(1.,std::round(params.at("size").get<double>()*height*.25));auto strings=lines(params.at("content"));std::vector<Line> layout;double total=gap*(strings.size()-1);for(const auto& text:strings){auto line=shape(font,text.empty()?"Ag":text);total+=std::ceil(line.top-line.bottom)+2*pad;layout.push_back(std::move(line));}std::vector<unsigned char> pixels(size_t(width)*height*4);auto bg=color(params,"background");for(size_t i=0;i<pixels.size();i+=4){for(int c=0;c<3;++c)pixels[i+c]=bg[c];pixels[i+3]=std::round(bg[3]*255);}double top=std::round(params.at("y").get<double>()*height-total/2),anchor=params.at("x").get<double>()*width;std::string align=params.at("align");for(size_t i=0;i<layout.size();++i){auto& line=layout[i];double h=std::ceil(line.top-line.bottom)+2*pad,w=std::ceil(line.right-line.left)+2*pad+std::floor(h*slant)+(slant?1:0);double left=std::round(align=="left"?anchor:align=="right"?anchor-w:anchor-w/2),baseline=top+pad+line.top;if(!strings[i].empty()){if(outline>0)for(const auto& glyph:line.glyphs)bitmap(font,glyph.id,weight+outline,left+pad-line.left+glyph.x,baseline-glyph.y,slant,color(params,"outline"),pixels,width,height);for(const auto& glyph:line.glyphs)bitmap(font,glyph.id,weight,left+pad-line.left+glyph.x,baseline-glyph.y,slant,color(params,"color"),pixels,width,height);}top+=h+gap;}png_image image{};image.version=PNG_IMAGE_VERSION;image.width=width;image.height=height;image.format=PNG_FORMAT_RGBA;if(!png_image_write_to_file(&image,destination.c_str(),0,pixels.data(),0,nullptr)){std::string message=image.message;png_image_free(&image);throw std::runtime_error("Text PNG: "+message);}png_image_free(&image);}

}
void installPortableTextBackends(){installTextRasterizer(raster,"freetype-harfbuzz-rgba-v1");}
}
