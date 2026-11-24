#include "flash_faces.hpp"
#include <iostream>
#include <stdexcept>
void require(bool value,const char *message){if(!value)throw std::runtime_error(message);}
int main(){
    try{
        nlohmann::json p={{"theme","custom"},{"colors",2},{"color_a","#ff0000"},{"color_b","#00ff00"},{"speed",2},{"on_time",1}};
        const auto palette=flash_faces::palette(p);
        const auto sample=[&](int face,double time){return flash_faces::sample(p,palette,face,3,time);};
        require(sample(0,0)==palette[0] && sample(1,0)==palette[1],"alternate faces must differ");
        require(sample(0,.5)==palette[1],"speed does not advance colors");
        p["speed"]=4;require(sample(0,.25)==palette[1],"speed does not double");
        p["speed"]=0;require(sample(0,100)==sample(0,0),"zero speed must be static");
        p["speed"]=2;p["on_time"]=.5;
        require(sample(0,.375)==flash_faces::Color{0,0,0},"off interval is not black");
        p["on_time"]=1;p["pattern"]="chase";
        require(sample(1,0)==flash_faces::Color{0,0,0} && sample(1,.5)!=flash_faces::Color{0,0,0},"chase does not move");
        p["pattern"]="strobe";require(sample(0,.2)==sample(2,.2),"strobe must synchronize faces");
        for(auto pattern:{"alternate","chase","shuffle","scatter","strobe","wave"}){
            p["pattern"]=pattern;p["fade"]=.8;p["on_time"]=.7;
            for(int face=0;face<3;face++)for(double time:{0.,.1,.4,10.,10000.}){
                auto a=sample(face,time),b=sample(face,time);require(a==b,"randomness must be reproducible");
                for(float value:a)require(std::isfinite(value)&&value>=0&&value<=1,"invalid sample range");
            }
        }
        for(auto theme:{"neon","ice","fire","candy","rgb","custom"}){
            p["theme"]=theme;
            for(int count=2;count<=6;count++){p["colors"]=count;require(flash_faces::palette(p).size()==std::size_t(count),"palette count ignored");}
        }
        std::cout<<"Flash Faces timing, patterns, colors, freeze, envelopes passed\n";
    }catch(const std::exception &error){std::cerr<<error.what()<<'\n';return 1;}
}
