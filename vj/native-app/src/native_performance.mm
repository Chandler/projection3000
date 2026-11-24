#import "native_performance.hpp"
#import "native_style.hpp"
#include <chrono>

namespace {
double monotonic(){return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();}
}
@implementation VJPerformanceBar {
    vj::Model* _model;
    NSTimer* _timer;
    NSArray<NSTextField*>* _values;
    dispatch_group_t _tasks;
    BOOL _closed,_busy;
    double _previousTick,_lastSample,_worstDelay,_recentDelay,_lastSlow;
    uint64_t _lateTicks;
}
- (instancetype)initWithModel:(vj::Model*)model {
    if((self=[super initWithFrame:NSMakeRect(0,0,800,26)])){
        _model=model;_tasks=dispatch_group_create();_previousTick=monotonic();
        self.identifier=@"performance-bar";self.wantsLayer=YES;self.layer.backgroundColor=vj::style::background().CGColor;
        auto row=vj::style::stack(NSUserInterfaceLayoutOrientationHorizontal);row.spacing=18;row.translatesAutoresizingMaskIntoConstraints=NO;[self addSubview:row];
        NSMutableArray* labels=[NSMutableArray array];
        for(NSString* initial in @[@"FPS —",@"Frame —",@"UI —",@"CPU —",@"RAM —"]){auto label=vj::style::label(initial);label.font=vj::style::valueFont();label.textColor=vj::style::secondary();[row addArrangedSubview:label];[label.widthAnchor constraintEqualToConstant:[initial isEqualToString:@"RAM —"]?110:120].active=YES;[labels addObject:label];}_values=labels;
        _values[0].toolTip=@"Completed render frames per second / target";
        _values[1].toolTip=@"Full render frame time, including mapping, readback and GPU completion";
        _values[2].toolTip=@"Main thread timer delay; slow events stay visible for five seconds";
        _values[3].toolTip=@"App CPU usage; 100% equals one CPU core";
        _values[4].toolTip=@"App resident memory";
        [NSLayoutConstraint activateConstraints:@[[row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],[row.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],[self.heightAnchor constraintEqualToConstant:26]]];
        __weak VJPerformanceBar* weak=self;_timer=[NSTimer timerWithTimeInterval:.1 repeats:YES block:^(NSTimer*){[weak tick];}];[[NSRunLoop mainRunLoop]addTimer:_timer forMode:NSRunLoopCommonModes];
    }return self;
}
- (void)tick {
    if(_closed)return;const double now=monotonic(),delay=std::max(0.,(now-_previousTick-.1)*1000);_previousTick=now;_worstDelay=std::max(_worstDelay,delay);
    if(delay>=50){++_lateTicks;_recentDelay=std::max(_recentDelay,delay);_lastSlow=now;}else if(now-_lastSlow>5)_recentDelay=delay;
    if(_busy||now-_lastSample<1)return;_lastSample=now;_busy=YES;
    const vj::Json ui={{"delayMs",_recentDelay},{"maxDelayMs",_worstDelay},{"lateTicks",_lateTicks},{"sampledAt",now}};
    dispatch_group_async(_tasks,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        self->_model->setControlRuntime("ui",ui);auto reply=self->_model->request("GET","/api/v1/stats");
        dispatch_async(dispatch_get_main_queue(),^{self->_busy=NO;if(self->_closed)return;if(reply.status!=200)return;
            const auto renderer=reply.body.value("renderer",vj::Json::object());auto metrics=renderer.value("metrics",vj::Json::object());if(!metrics.is_object())metrics=vj::Json::object();
            const double age=monotonic()-metrics.value("sampledAt",0.);const bool stale=age>2.5||!metrics.contains("fps");
            const double fps=metrics.value("fps",0.),target=metrics.value("targetFps",60.);
            self->_values[0].stringValue=metrics.empty()?@"FPS —":stale?@"FPS — stopped":[NSString stringWithFormat:@"FPS %.1f / %.0f",fps,target];
            self->_values[0].textColor=metrics.empty()?vj::style::secondary():stale?vj::style::danger():fps<target*.85?vj::style::warning():vj::style::secondary();
            self->_values[1].stringValue=stale?@"Frame —":[NSString stringWithFormat:@"Frame %.1f ms",metrics.value("frameMs",0.)];
            self->_values[2].stringValue=[NSString stringWithFormat:@"UI %.0f ms",self->_recentDelay];self->_values[2].textColor=self->_recentDelay>=50?vj::style::warning():vj::style::secondary();
            const auto processes=reply.body.value("processes",vj::Json::array());if(!processes.empty()){auto cpu=processes[0].value("cpuPercent",vj::Json());self->_values[3].stringValue=cpu.is_number()?[NSString stringWithFormat:@"CPU %.0f%%",cpu.get<double>()]:@"CPU —";self->_values[4].stringValue=[NSString stringWithFormat:@"RAM %.2f GB",processes[0].value("rssBytes",0.)/(1024.*1024*1024)];}
        });
    });
}
- (void)drawRect:(NSRect)rect {(void)rect;[vj::style::border()setFill];NSRectFill(NSMakeRect(0,self.bounds.size.height-1,self.bounds.size.width,1));}
- (void)stop {if(_closed)return;_closed=YES;[_timer invalidate];_timer=nil;dispatch_group_wait(_tasks,DISPATCH_TIME_FOREVER);}
- (void)dealloc {[_timer invalidate];}
@end
