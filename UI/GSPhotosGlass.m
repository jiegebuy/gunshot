#import "GSPhotosGlass.h"
#import "../Shared/GSPhotosCompatibility.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>

static NSString *const GSPhotosGlassPreference=@"GSPhotosBottomBarLiquidGlass";
static char GSGlassPairKey;
static BOOL GSInstalled;
static NSHashTable *GSControllers,*GSPairs;
static NSString *GSLastSkip;

// The native controls keep their targets, gestures, children and accessibility.
// All associations and UIKit mutations are confined to the main thread.
@interface GSPhotosGlassPair : NSObject
@property(nonatomic,weak) UIViewController *controller;
@property(nonatomic,weak) UIStackView *bar;
@property(nonatomic,weak) UIControl *segments;
@property(nonatomic,weak) UIButton *search;
@property(nonatomic,weak) UIView *shadow,*content;
@property(nonatomic,weak) UIVisualEffectView *nativeEffect;
@property(nonatomic,strong) UIVisualEffectView *effect;
@property(nonatomic,strong) UIColor *controlColor,*shadowColor,*contentColor;
@property(nonatomic,strong) UIColor *searchColor,*searchHighlightedColor,*searchTint;
@property(nonatomic,strong) id searchShadow;
@property(nonatomic) BOOL controlOpaque,shadowOpaque,contentOpaque,controlClips,adaptive,changing;
@property(nonatomic) double elevation;
@end
@implementation GSPhotosGlassPair @end

static id GSGet(id object,NSString *name){
 if(!GSPhotosHasMethod(object_getClass(object),name,"@16@0:8"))return nil;
 return ((id(*)(id,SEL))objc_msgSend)(object,NSSelectorFromString(name));
}
static NSInteger GSInteger(id object,NSString *name){return ((NSInteger(*)(id,SEL))objc_msgSend)(object,NSSelectorFromString(name));}
static void GSCall(id object,NSString *name){((void(*)(id,SEL))objc_msgSend)(object,NSSelectorFromString(name));}
static id GSStateValue(id object,NSString *name,UIControlState state){return ((id(*)(id,SEL,NSUInteger))objc_msgSend)(object,NSSelectorFromString(name),state);}
static void GSSetStateValue(id object,NSString *name,id value,UIControlState state){((void(*)(id,SEL,id,NSUInteger))objc_msgSend)(object,NSSelectorFromString(name),value,state);}
static double GSElevation(id shadow){return ((double(*)(id,SEL))objc_msgSend)(shadow,NSSelectorFromString(@"mdc_currentElevation"));}
static void GSSetElevation(id shadow,double value){((void(*)(id,SEL,double))objc_msgSend)(shadow,NSSelectorFromString(@"setElevation:"),value);}
static BOOL GSAdaptive(id shadow){return ((BOOL(*)(id,SEL))objc_msgSend)(shadow,NSSelectorFromString(@"adaptiveBackgroundColorEnabled"));}
static void GSSetAdaptive(id shadow,BOOL value){((void(*)(id,SEL,BOOL))objc_msgSend)(shadow,NSSelectorFromString(@"setAdaptiveBackgroundColorEnabled:"),value);}
BOOL GSPhotosGlassEnabled(void){return [NSUserDefaults.standardUserDefaults boolForKey:GSPhotosGlassPreference];}

static NSString *GSUnavailableReason(void){
 if(@available(iOS 26.0,*)){
  if(!GSPhotosHostSupported())return @"unsupported_host";
  id version=[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
  if(![version isKindOfClass:NSString.class]||
     [version rangeOfString:@"^[0-9]+\\.[0-9]+(?:\\.[0-9]+)?$" options:NSRegularExpressionSearch].location==NSNotFound)return @"unknown_version";
  if([version compare:@"7.92" options:NSNumericSearch]==NSOrderedAscending)return @"requires_photos_7_92";
  // 7.92.0 was audited. Newer versions must expose the same native contracts
  // and pass the per-controller hierarchy checks before any view is changed.
  for(NSArray *entry in @[
   @[@"PHSTabBarController",@"viewDidLayoutSubviews",@"v16@0:8"],
   @[@"PHSTabBarController",@"floatingBottomTabBar",@"@16@0:8"],
   @[@"PHSTabBarController",@"floatingSegmentedControl",@"@16@0:8"],
   @[@"PHSTabBarController",@"floatingSearchButton",@"@16@0:8"],
   @[@"PHSSegmentedControl",@"layoutSubviews",@"v16@0:8"],
   @[@"PHSSegmentedControl",@"traitCollectionDidChange:",@"v24@0:8@16"],
   @[@"PHSShadowView",@"mdc_currentElevation",@"d16@0:8"],
   @[@"PHSShadowView",@"setElevation:",@"v24@0:8d16"],
   @[@"PHSShadowView",@"adaptiveBackgroundColorEnabled",@"B16@0:8"],
   @[@"PHSShadowView",@"setAdaptiveBackgroundColorEnabled:",@"v20@0:8B16"],
   @[@"M3CButton",@"layoutSubviews",@"v16@0:8"],
   @[@"M3CButton",@"phs_brandIconTonalRound",@"v16@0:8"],
   @[@"M3CButton",@"phs_brandIconTonalGlassRound",@"v16@0:8"],
   @[@"M3CButton",@"glassType",@"q16@0:8"],
   @[@"M3CButton",@"isGlassEnabled",@"B16@0:8"],
   @[@"M3CButton",@"glassEffectView",@"@16@0:8"],
   @[@"M3CButton",@"backgroundColorForState:",@"@24@0:8Q16"],
   @[@"M3CButton",@"shadowForState:",@"@24@0:8Q16"],
   @[@"M3CButton",@"tintColorForState:",@"@24@0:8Q16"],
   @[@"M3CButton",@"setBackgroundColor:forState:",@"v32@0:8@16Q24"],
   @[@"M3CButton",@"setShadow:forState:",@"v32@0:8@16Q24"],
   @[@"M3CButton",@"setTintColor:forState:",@"v32@0:8@16Q24"],
   @[@"M3CMaterialGlassEffectView",@"isGlass",@"B16@0:8"],
   @[@"M3CMaterialGlassEffectView",@"glass",@"@16@0:8"],
   @[@"M3CMaterialGlassEffectView",@"updateGlassEffect",@"v16@0:8"],
   @[@"M3CMaterialGlassEffect",@"type",@"q16@0:8"]])
   if(!GSPhotosHasMethod(NSClassFromString(entry[0]),entry[1],[entry[2]UTF8String]))return [NSString stringWithFormat:@"missing_contract:%@.%@",entry[0],entry[1]];
  if(![NSClassFromString(@"UIGlassEffect") respondsToSelector:NSSelectorFromString(@"effectWithStyle:")])return @"missing_glass_api";
  if(![NSClassFromString(@"UICornerConfiguration") respondsToSelector:NSSelectorFromString(@"capsuleConfiguration")]||
     ![UIVisualEffectView instancesRespondToSelector:NSSelectorFromString(@"setCornerConfiguration:")])return @"missing_corner_api";
  return nil;
 }
 return @"requires_ios_26";
}
BOOL GSPhotosGlassAvailable(void){return GSUnavailableReason()==nil;}

static void GSRestore(GSPhotosGlassPair *pair){
 if(!pair||pair.changing)return;
 pair.changing=YES;
 BOOL ownsSearch=objc_getAssociatedObject(pair.search,&GSGlassPairKey)==pair;
 // Keep the controller's changing marker until native restyling completes, so
 // a synchronous controller layout cannot attach another pair during restore.
 for(id object in @[pair.segments?:NSNull.null,pair.search?:NSNull.null,pair.nativeEffect?:NSNull.null])
  if(object!=NSNull.null&&objc_getAssociatedObject(object,&GSGlassPairKey)==pair)objc_setAssociatedObject(object,&GSGlassPairKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
 [pair.effect removeFromSuperview];
 pair.segments.backgroundColor=pair.controlColor;pair.segments.opaque=pair.controlOpaque;pair.segments.clipsToBounds=pair.controlClips;
 pair.content.backgroundColor=pair.contentColor;pair.content.opaque=pair.contentOpaque;
 pair.shadow.backgroundColor=pair.shadowColor;pair.shadow.opaque=pair.shadowOpaque;
 GSSetAdaptive(pair.shadow,pair.adaptive);GSSetElevation(pair.shadow,pair.elevation);
 // Reapply the same native style used by createFloatingSearchButton. This also
 // recomputes normal state colors and shadows; changing glassType alone does not.
 if(ownsSearch){
  GSCall(pair.search,@"phs_brandIconTonalRound");
  // Photos overrides the tonal defaults after creating this button. Preserve
  // those dynamic colors and elevation shadow as well as the native style.
  GSSetStateValue(pair.search,@"setBackgroundColor:forState:",pair.searchColor,UIControlStateNormal);
  GSSetStateValue(pair.search,@"setBackgroundColor:forState:",pair.searchHighlightedColor,UIControlStateHighlighted);
  GSSetStateValue(pair.search,@"setTintColor:forState:",pair.searchTint,UIControlStateNormal);
  GSSetStateValue(pair.search,@"setShadow:forState:",pair.searchShadow,UIControlStateNormal);
 }
 if(pair.nativeEffect&&GSGet(pair.search,@"glassEffectView")!=pair.nativeEffect)GSCall(pair.nativeEffect,@"updateGlassEffect");
 if(objc_getAssociatedObject(pair.controller,&GSGlassPairKey)==pair)objc_setAssociatedObject(pair.controller,&GSGlassPairKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
 [GSPairs removeObject:pair];
}

static BOOL GSLayoutPill(GSPhotosGlassPair *pair){
 if(!pair||pair.changing)return NO;
 if(pair.segments.superview!=pair.bar||pair.search.superview!=pair.bar||pair.shadow.superview!=pair.segments||pair.content.superview!=pair.shadow){
  GSRestore(pair);GSLastSkip=@"bottom_bar_hierarchy_changed";return NO;
 }
 pair.changing=YES;
 // Remember native theme updates for opt-out, then remove every opaque surface
 // covering the effect (including the control itself, not just its children).
 if(![pair.segments.backgroundColor isEqual:UIColor.clearColor])pair.controlColor=pair.segments.backgroundColor;
 if(![pair.content.backgroundColor isEqual:UIColor.clearColor])pair.contentColor=pair.content.backgroundColor;
 if(![pair.shadow.backgroundColor isEqual:UIColor.clearColor])pair.shadowColor=pair.shadow.backgroundColor;
 if(GSAdaptive(pair.shadow))GSSetAdaptive(pair.shadow,NO);
 if(GSElevation(pair.shadow)!=0)GSSetElevation(pair.shadow,0);
 if(![pair.segments.backgroundColor isEqual:UIColor.clearColor])pair.segments.backgroundColor=UIColor.clearColor;
 if(![pair.content.backgroundColor isEqual:UIColor.clearColor])pair.content.backgroundColor=UIColor.clearColor;
 if(![pair.shadow.backgroundColor isEqual:UIColor.clearColor])pair.shadow.backgroundColor=UIColor.clearColor;
 pair.segments.opaque=NO;pair.content.opaque=NO;pair.shadow.opaque=NO;pair.segments.clipsToBounds=NO;
 if(pair.effect.superview!=pair.segments)[pair.segments insertSubview:pair.effect atIndex:0];
 if(!CGRectEqualToRect(pair.effect.frame,pair.segments.bounds))pair.effect.frame=pair.segments.bounds;
 pair.changing=NO;return YES;
}

static void GSUpdateController(UIViewController *controller){
 [GSControllers addObject:controller];
 GSPhotosGlassPair *previous=objc_getAssociatedObject(controller,&GSGlassPairKey);
 if(!GSPhotosGlassEnabled()){GSRestore(previous);return;}
 if(previous.changing)return;
 UIStackView *bar=GSGet(controller,@"floatingBottomTabBar");
 UIControl *segments=GSGet(controller,@"floatingSegmentedControl");
 UIButton *search=GSGet(controller,@"floatingSearchButton");
 UIVisualEffectView *native=GSGet(search,@"glassEffectView");
 if(previous&&previous.bar==bar&&previous.segments==segments&&previous.search==search&&previous.nativeEffect==native){
  if(GSLayoutPill(previous)&&GSInteger(search,@"glassType")==0){
   previous.changing=YES;GSCall(search,@"phs_brandIconTonalGlassRound");previous.changing=NO;
  }
  return;
 }
 GSRestore(previous);
 if(![bar isKindOfClass:UIStackView.class]||![segments isKindOfClass:UIControl.class]||![segments isKindOfClass:NSClassFromString(@"PHSSegmentedControl")]||
    ![search isKindOfClass:UIButton.class]||![search isKindOfClass:NSClassFromString(@"M3CButton")]||segments.superview!=bar||search.superview!=bar){GSLastSkip=@"floating_bottom_bar_not_found";return;}
 // Validate BOTH targets before applying either. Never leave a half-converted bar.
 if(![native isKindOfClass:UIVisualEffectView.class]||![native isKindOfClass:NSClassFromString(@"M3CMaterialGlassEffectView")]||native.superview!=search){GSLastSkip=@"search_material_view_not_found";return;}
 if(objc_getAssociatedObject(segments,&GSGlassPairKey)||objc_getAssociatedObject(search,&GSGlassPairKey)||GSInteger(search,@"glassType")!=0){GSLastSkip=@"search_style_already_customized";return;}
 UIView *shadow=nil,*content=nil;
 for(UIView *candidate in segments.subviews)if([candidate isKindOfClass:NSClassFromString(@"PHSShadowView")]){
  for(UIView *child in candidate.subviews)if(child.accessibilityTraits&UIAccessibilityTraitTabBar){
   if(content){GSLastSkip=@"ambiguous_segment_content";return;}shadow=candidate;content=child;
  }
 }
 if(!content){GSLastSkip=@"segment_content_not_found";return;}
 id glass=((id(*)(id,SEL,NSInteger))objc_msgSend)(NSClassFromString(@"UIGlassEffect"),NSSelectorFromString(@"effectWithStyle:"),0);
 if(![glass isKindOfClass:UIVisualEffect.class]){GSLastSkip=@"glass_creation_failed";return;}
 GSPhotosGlassPair *pair=[GSPhotosGlassPair new];pair.controller=controller;pair.bar=bar;pair.segments=segments;pair.search=search;
 pair.shadow=shadow;pair.content=content;pair.nativeEffect=native;
 pair.controlColor=segments.backgroundColor;pair.shadowColor=shadow.backgroundColor;pair.contentColor=content.backgroundColor;
 pair.searchColor=GSStateValue(search,@"backgroundColorForState:",UIControlStateNormal);
 pair.searchHighlightedColor=GSStateValue(search,@"backgroundColorForState:",UIControlStateHighlighted);
 pair.searchTint=GSStateValue(search,@"tintColorForState:",UIControlStateNormal);
 pair.searchShadow=GSStateValue(search,@"shadowForState:",UIControlStateNormal);
 pair.controlOpaque=segments.opaque;pair.shadowOpaque=shadow.opaque;pair.contentOpaque=content.opaque;pair.controlClips=segments.clipsToBounds;
 pair.adaptive=GSAdaptive(shadow);pair.elevation=GSElevation(shadow);
 // Configure the material's shape through UIKit, without clipping its edge/shadow.
 pair.effect=[[UIVisualEffectView alloc]initWithEffect:glass];pair.effect.userInteractionEnabled=NO;
 pair.effect.accessibilityElementsHidden=YES;pair.effect.clipsToBounds=NO;
 id corners=((id(*)(id,SEL))objc_msgSend)(NSClassFromString(@"UICornerConfiguration"),NSSelectorFromString(@"capsuleConfiguration"));
 ((void(*)(id,SEL,id))objc_msgSend)(pair.effect,NSSelectorFromString(@"setCornerConfiguration:"),corners);
 for(id object in @[controller,segments,search,native])objc_setAssociatedObject(object,&GSGlassPairKey,pair,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
 [GSPairs addObject:pair];
 pair.changing=YES;GSCall(search,@"phs_brandIconTonalGlassRound");pair.changing=NO;
 if(![native.effect isKindOfClass:NSClassFromString(@"UIGlassEffect")]){GSRestore(pair);GSLastSkip=@"native_glass_effect_not_created";return;}
 if(GSLayoutPill(pair))GSLastSkip=nil;
}

static void GSVisitController(UIViewController *controller,NSMutableSet *seen){
 if(!controller||[seen containsObject:controller])return;
 [seen addObject:controller];
 if(controller.isViewLoaded&&[controller isKindOfClass:NSClassFromString(@"PHSTabBarController")])GSUpdateController(controller);
 for(UIViewController *child in controller.childViewControllers)GSVisitController(child,seen);
 GSVisitController(controller.presentedViewController,seen);
}
static void GSDiscoverControllers(void){
 if(!GSInstalled)return;
 NSMutableSet *seen=[NSMutableSet set];
 for(UIScene *scene in UIApplication.sharedApplication.connectedScenes)if([scene isKindOfClass:UIWindowScene.class])
  for(UIWindow *window in ((UIWindowScene *)scene).windows)GSVisitController(window.rootViewController,seen);
}
static void GSHook(Class cls,NSString *name,IMP replacement){
 SEL selector=NSSelectorFromString(name);Method method=class_getInstanceMethod(cls,selector);
 class_replaceMethod(cls,selector,replacement,method_getTypeEncoding(method));
}
void GSInstallPhotosGlass(void){
 if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{GSInstallPhotosGlass();});return;}
 if(GSInstalled||!GSPhotosGlassAvailable())return;
 GSControllers=NSHashTable.weakObjectsHashTable;GSPairs=NSHashTable.weakObjectsHashTable;
 Class cls=NSClassFromString(@"PHSTabBarController");SEL layout=@selector(viewDidLayoutSubviews);
 IMP controllerLayout=method_getImplementation(class_getInstanceMethod(cls,layout));
 GSHook(cls,@"viewDidLayoutSubviews",imp_implementationWithBlock(^(UIViewController *controller){((void(*)(id,SEL))controllerLayout)(controller,layout);GSUpdateController(controller);}));
 cls=NSClassFromString(@"PHSSegmentedControl");
 IMP segmentLayout=method_getImplementation(class_getInstanceMethod(cls,@selector(layoutSubviews)));
 GSHook(cls,@"layoutSubviews",imp_implementationWithBlock(^(UIView *view){((void(*)(id,SEL))segmentLayout)(view,@selector(layoutSubviews));GSLayoutPill(objc_getAssociatedObject(view,&GSGlassPairKey));}));
 SEL trait=NSSelectorFromString(@"traitCollectionDidChange:");IMP oldTrait=method_getImplementation(class_getInstanceMethod(cls,trait));
 GSHook(cls,@"traitCollectionDidChange:",imp_implementationWithBlock(^(UIView *view,id previous){((void(*)(id,SEL,id))oldTrait)(view,trait,previous);GSLayoutPill(objc_getAssociatedObject(view,&GSGlassPairKey));}));
 cls=NSClassFromString(@"M3CButton");SEL enabled=NSSelectorFromString(@"isGlassEnabled");IMP oldEnabled=method_getImplementation(class_getInstanceMethod(cls,enabled));
 GSHook(cls,@"isGlassEnabled",imp_implementationWithBlock(^BOOL(id button){
  GSPhotosGlassPair *pair=objc_getAssociatedObject(button,&GSGlassPairKey);
  return pair.search==button?GSInteger(button,@"glassType")!=0:((BOOL(*)(id,SEL))oldEnabled)(button,enabled);
 }));
 SEL brand=NSSelectorFromString(@"phs_brandIconTonalRound");IMP oldBrand=method_getImplementation(class_getInstanceMethod(cls,brand));
 GSHook(cls,@"phs_brandIconTonalRound",imp_implementationWithBlock(^(id button){
  GSPhotosGlassPair *pair=objc_getAssociatedObject(button,&GSGlassPairKey);
  if(pair.search==button)GSCall(button,@"phs_brandIconTonalGlassRound");else ((void(*)(id,SEL))oldBrand)(button,brand);
 }));
 IMP buttonLayout=method_getImplementation(class_getInstanceMethod(cls,@selector(layoutSubviews)));
 GSHook(cls,@"layoutSubviews",imp_implementationWithBlock(^(id button){
  ((void(*)(id,SEL))buttonLayout)(button,@selector(layoutSubviews));
  GSPhotosGlassPair *pair=objc_getAssociatedObject(button,&GSGlassPairKey);
  if(pair&&!pair.changing&&pair.controller&&(GSGet(button,@"glassEffectView")!=pair.nativeEffect||GSInteger(button,@"glassType")==0))GSUpdateController(pair.controller);
 }));
 cls=NSClassFromString(@"M3CMaterialGlassEffectView");SEL isGlass=NSSelectorFromString(@"isGlass");IMP oldGlass=method_getImplementation(class_getInstanceMethod(cls,isGlass));
 GSHook(cls,@"isGlass",imp_implementationWithBlock(^BOOL(id effect){
  GSPhotosGlassPair *pair=objc_getAssociatedObject(effect,&GSGlassPairKey);
  return pair.search&&pair.nativeEffect==effect&&objc_getAssociatedObject(pair.search,&GSGlassPairKey)==pair?
   GSInteger(GSGet(effect,@"glass"),@"type")!=0:((BOOL(*)(id,SEL))oldGlass)(effect,isGlass);
 }));
 GSInstalled=YES;GSDiscoverControllers();
}
void GSSetPhotosGlass(BOOL enabled){
 if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{GSSetPhotosGlass(enabled);});return;}
 GSInstallPhotosGlass();if(enabled&&!GSInstalled)return;
 [NSUserDefaults.standardUserDefaults setBool:enabled forKey:GSPhotosGlassPreference];GSLastSkip=nil;
 if(!enabled)for(GSPhotosGlassPair *pair in GSPairs.allObjects)GSRestore(pair);
 else{GSDiscoverControllers();for(UIViewController *controller in GSControllers.allObjects)GSUpdateController(controller);}
}
NSDictionary *GSPhotosGlassSnapshot(void){
 if(!NSThread.isMainThread){__block NSDictionary *snapshot;dispatch_sync(dispatch_get_main_queue(),^{snapshot=GSPhotosGlassSnapshot();});return snapshot;}
 NSUInteger attached=0;
 for(GSPhotosGlassPair *pair in GSPairs.allObjects)if(pair.segments&&pair.search&&pair.effect.superview==pair.segments&&pair.nativeEffect.superview==pair.search)attached++;
 NSString *unavailable=GSUnavailableReason();
 return @{@"enabled":@(GSPhotosGlassEnabled()),@"available":@(unavailable==nil),@"hooksInstalled":@(GSInstalled),
  @"controllersSeen":@(GSControllers.count),@"attachedBars":@(attached),
  @"reason":unavailable?:(attached?@"attached":GSLastSkip?:(GSPhotosGlassEnabled()?@"waiting_for_bottom_bar":@"disabled")),
  @"lastSkipReason":GSLastSkip?:NSNull.null};
}
__attribute__((constructor)) static void GSLoadPhotosGlass(void){
 @autoreleasepool{
  if(!GSPhotosHostSupported())return;
  [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){GSInstallPhotosGlass();GSDiscoverControllers();}];
  dispatch_async(dispatch_get_main_queue(),^{GSInstallPhotosGlass();});
 }
}
