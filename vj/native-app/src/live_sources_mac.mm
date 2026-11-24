#include "live_sources.hpp"
#import <AVFoundation/AVFoundation.h>
#include <map>

nlohmann::json nativeCameraSources(){@autoreleasepool{
    using Json=nlohmann::json;Json cameras=Json::array();
    // Listing never creates AVCaptureDeviceInput/AVCaptureSession or requests
    // authorization. Names/indices match FFmpeg AVFoundation's video device list.
    NSArray<AVCaptureDevice*>* devices=[AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    std::map<std::string,int> counts;
    for(AVCaptureDevice* device in devices)++counts[device.localizedName.UTF8String?:""];
    int index=0;
    for(AVCaptureDevice* device in devices){
        const std::string name=device.localizedName.UTF8String?:"";
        auto selection=vj::normalizeLiveSelection("usb_webcam",name);
        if(selection.empty()||counts[name]>1)selection=std::to_string(index);
        cameras.push_back({{"device",selection},{"selection",selection},{"label",name},{"node","Camera "+std::to_string(index)},{"uniqueId",device.uniqueID.UTF8String?:""}});++index;
    }
    const auto status=[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    const std::string authorization=status==AVAuthorizationStatusAuthorized?"authorized":status==AVAuthorizationStatusDenied?"denied":status==AVAuthorizationStatusRestricted?"restricted":"not-determined";
    return {{"available",true},{"sources",cameras},{"cameras",cameras},{"authorization",authorization}};
}}
