#import "GSPhotosGlass.h"
#import "../Shared/GSPhotosCompatibility.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const GSPhotosGlassPreference=@"GSPhotosBottomBarLiquidGlass";
static NSString *const GSDesignCompatibilityOverride=@"com.apple.SwiftUI.IgnoreSolariumOptOut";
static char GSGlassPairKey;
static BOOL GSInstalled,GSBootGlassEnabled,GSRestartRequired,GSDesignOverrideApplied;
static NSHashTable *GSControllers,*GSPairs;
static NSString *GSLastSkip;

@class GSPhotosGlassPair;

@interface GSPhotosGlassValueChangeProbe : NSObject
@property(nonatomic) BOOL fired;
- (void)valueChanged:(id)sender;
@end
@implementation GSPhotosGlassValueChangeProbe
- (void)valueChanged:(id)sender{self.fired=YES;}
@end

@interface GSPhotosGlassTabView : UIControl
@property(nonatomic,weak) GSPhotosGlassPair *owner;
@property(nonatomic,strong) UIVisualEffectView *outerGlass;
@property(nonatomic,strong) NSArray<UIButton *> *buttons;
@property(nonatomic) NSInteger selectedIndex;
- (instancetype)initWithTitles:(NSArray<NSString *> *)titles symbols:(NSArray<NSString *> *)symbols owner:(GSPhotosGlassPair *)owner;
- (void)setSelectedIndex:(NSInteger)selectedIndex animated:(BOOL)animated;
@end

// Google Photos keeps owning the real segmented control and search button. The
// visible controls are UIKit-native glass proxies, while the real Google controls
// stay in place as the navigation/action backend. Do not insert a foreign view
// controller into PHSTabBarController: Photos treats every child controller as
// one of its destinations and will send it private selectors such as destination.
@interface GSPhotosGlassPair : NSObject
@property(nonatomic,weak) UIViewController *controller;
@property(nonatomic,weak) UIStackView *bar;
@property(nonatomic,weak) UIView *host;
@property(nonatomic,weak) UIControl *segments;
@property(nonatomic,weak) UIButton *search;
@property(nonatomic,strong) GSPhotosGlassTabView *tabProxy;
@property(nonatomic,strong) UIButton *searchProxy;
@property(nonatomic) CGFloat segmentsAlpha,searchAlpha;
@property(nonatomic) BOOL segmentsInteraction,searchInteraction;
@property(nonatomic) BOOL segmentsAccessibilityHidden,searchAccessibilityHidden,changing;
- (void)tabPressed:(UIButton *)sender;
- (void)searchPressed:(UIButton *)sender;
@end

static id GSGet(id object,NSString *name){
 if(!object||!GSPhotosHasMethod(object_getClass(object),name,"@16@0:8"))return nil;
 return ((id(*)(id,SEL))objc_msgSend)(object,NSSelectorFromString(name));
}
static NSInteger GSInteger(id object,NSString *name){return ((NSInteger(*)(id,SEL))objc_msgSend)(object,NSSelectorFromString(name));}
static void GSSetInteger(id object,NSString *name,NSInteger value){((void(*)(id,SEL,NSInteger))objc_msgSend)(object,NSSelectorFromString(name),value);}
BOOL GSPhotosGlassEnabled(void){return [NSUserDefaults.standardUserDefaults boolForKey:GSPhotosGlassPreference];}

static BOOL GSPhotosGlassHostVersionSupported(void){
 if(!GSPhotosHostSupported())return NO;
 id version=[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
 if(![version isKindOfClass:NSString.class]||
    [version rangeOfString:@"^[0-9]+\\.[0-9]+(?:\\.[0-9]+)?$" options:NSRegularExpressionSearch].location==NSNotFound)return NO;
 return [version compare:@"7.92" options:NSNumericSearch]!=NSOrderedAscending;
}

static void GSWriteDesignCompatibilityOverride(BOOL enabled){
 if(!GSPhotosHostSupported())return;
 if(@available(iOS 26.0,*)){
  NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
  if(enabled&&GSPhotosGlassHostVersionSupported())[defaults setBool:YES forKey:GSDesignCompatibilityOverride];
  else [defaults removeObjectForKey:GSDesignCompatibilityOverride];
  [defaults synchronize];
 }
}

static BOOL GSPhotosGlassActiveThisLaunch(void){return GSPhotosGlassEnabled()&&!GSRestartRequired&&GSDesignOverrideApplied;}

static NSString *GSUnavailableReason(void){
 if(@available(iOS 26.0,*)){
  if(!GSPhotosHostSupported())return @"unsupported_host";
  id version=[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
  if(![version isKindOfClass:NSString.class]||
     [version rangeOfString:@"^[0-9]+\\.[0-9]+(?:\\.[0-9]+)?$" options:NSRegularExpressionSearch].location==NSNotFound)return @"unknown_version";
  if(!GSPhotosGlassHostVersionSupported())return @"requires_photos_7_92";
  for(NSArray *entry in @[
   @[@"PHSTabBarController",@"viewDidLayoutSubviews",@"v16@0:8"],
   @[@"PHSTabBarController",@"floatingBottomTabBar",@"@16@0:8"],
   @[@"PHSTabBarController",@"floatingSegmentedControl",@"@16@0:8"],
   @[@"PHSTabBarController",@"floatingSearchButton",@"@16@0:8"],
   @[@"PHSSegmentedControl",@"layoutSubviews",@"v16@0:8"],
   @[@"PHSSegmentedControl",@"traitCollectionDidChange:",@"v24@0:8@16"],
   @[@"PHSSegmentedControl",@"numberOfSegments",@"q16@0:8"],
   @[@"PHSSegmentedControl",@"selectedSegmentIndex",@"q16@0:8"],
   @[@"PHSSegmentedControl",@"setSelectedSegmentIndex:",@"v24@0:8q16"],
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
  if(![NSClassFromString(@"UIButtonConfiguration") respondsToSelector:NSSelectorFromString(@"glassButtonConfiguration")])return @"missing_glass_button_api";
  return nil;
 }
 return @"requires_ios_26";
}
BOOL GSPhotosGlassAvailable(void){return GSUnavailableReason()==nil;}

static id GSCapsuleConfiguration(void){
 Class cls=NSClassFromString(@"UICornerConfiguration");SEL sel=NSSelectorFromString(@"capsuleConfiguration");
 return [cls respondsToSelector:sel]?((id(*)(id,SEL))objc_msgSend)(cls,sel):nil;
}
static id GSGlassEffect(BOOL interactive){
 Class cls=NSClassFromString(@"UIGlassEffect");SEL create=NSSelectorFromString(@"effectWithStyle:");
 if(![cls respondsToSelector:create])return nil;
 id effect=((id(*)(id,SEL,NSInteger))objc_msgSend)(cls,create,0);
 SEL setInteractive=NSSelectorFromString(@"setInteractive:");
 if(interactive&&[effect respondsToSelector:setInteractive])((void(*)(id,SEL,BOOL))objc_msgSend)(effect,setInteractive,YES);
 return effect;
}
static UIVisualEffectView *GSGlassCapsuleView(BOOL interactive){
 id effect=GSGlassEffect(interactive);if(!effect)return nil;
 UIVisualEffectView *view=[[UIVisualEffectView alloc]initWithEffect:effect];
 id capsule=GSCapsuleConfiguration();SEL setCorner=NSSelectorFromString(@"setCornerConfiguration:");
 if(capsule&&[view respondsToSelector:setCorner])((void(*)(id,SEL,id))objc_msgSend)(view,setCorner,capsule);
 view.backgroundColor=UIColor.clearColor;view.opaque=NO;view.clipsToBounds=NO;view.userInteractionEnabled=interactive;
 return view;
}
static UIButtonConfiguration *GSTabButtonConfiguration(NSString *title,UIImage *image,BOOL glass){
 UIButtonConfiguration *configuration=nil;
 Class cls=NSClassFromString(@"UIButtonConfiguration");
 if(glass&&[cls respondsToSelector:NSSelectorFromString(@"glassButtonConfiguration")])
  configuration=((id(*)(id,SEL))objc_msgSend)(cls,NSSelectorFromString(@"glassButtonConfiguration"));
 if(!configuration)configuration=[UIButtonConfiguration plainButtonConfiguration];
 UIColor *foreground=glass?UIColor.systemBlueColor:UIColor.labelColor;
 configuration.title=title;configuration.image=image;configuration.baseForegroundColor=foreground;
 configuration.imagePlacement=NSDirectionalRectEdgeTop;configuration.imagePadding=1.5;
 configuration.contentInsets=NSDirectionalEdgeInsetsMake(3,2,3,2);
 configuration.cornerStyle=UIButtonConfigurationCornerStyleCapsule;
 configuration.preferredSymbolConfigurationForImage=[UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightRegular];
 return configuration;
}

@implementation GSPhotosGlassTabView
- (instancetype)initWithTitles:(NSArray<NSString *> *)titles symbols:(NSArray<NSString *> *)symbols owner:(GSPhotosGlassPair *)owner{
 if((self=[super initWithFrame:CGRectZero])){
  _owner=owner;self.backgroundColor=UIColor.clearColor;self.opaque=NO;self.clipsToBounds=NO;self.isAccessibilityElement=NO;
  _outerGlass=GSGlassCapsuleView(NO);if(!_outerGlass)return nil;[self addSubview:_outerGlass];
  NSMutableArray<UIButton *> *buttons=[NSMutableArray arrayWithCapacity:titles.count];
  for(NSInteger i=0;i<(NSInteger)titles.count;i++){
   UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.tag=i;button.clipsToBounds=NO;
   button.accessibilityLabel=titles[i];button.accessibilityTraits=UIAccessibilityTraitButton;
   UIImage *image=i<(NSInteger)symbols.count?[UIImage systemImageNamed:symbols[i]]:nil;
   button.configuration=GSTabButtonConfiguration(titles[i],image,i==0);
   __weak UIButton *weakButton=button;__weak typeof(self) weakSelf=self;
   button.configurationUpdateHandler=^(UIButton *updated){
    UIButton *strongButton=weakButton?:updated;GSPhotosGlassTabView *strongSelf=weakSelf;if(!strongButton||!strongSelf)return;
    BOOL active=strongButton.selected||strongButton.highlighted;
    NSString *buttonTitle=strongButton.accessibilityLabel?:@"";
    UIImage *buttonImage=i<(NSInteger)symbols.count?[UIImage systemImageNamed:symbols[i]]:nil;
    strongButton.configuration=GSTabButtonConfiguration(buttonTitle,buttonImage,active);
   };
   [button addTarget:owner action:@selector(tabPressed:) forControlEvents:UIControlEventTouchUpInside];
   [self addSubview:button];[buttons addObject:button];
  }
  _buttons=buttons.copy;_selectedIndex=0;[self setSelectedIndex:0 animated:NO];
 }
 return self;
}
- (void)setSelectedIndex:(NSInteger)selectedIndex{[self setSelectedIndex:selectedIndex animated:NO];}
- (void)setSelectedIndex:(NSInteger)selectedIndex animated:(BOOL)animated{
 if(selectedIndex<0||selectedIndex>=(NSInteger)self.buttons.count)return;
 _selectedIndex=selectedIndex;
 void (^changes)(void)=^{
  for(UIButton *button in self.buttons){
   BOOL selected=button.tag==selectedIndex;button.selected=selected;
   button.accessibilityTraits=UIAccessibilityTraitButton|(selected?UIAccessibilityTraitSelected:0);
   [button setNeedsUpdateConfiguration];
  }
  [self layoutIfNeeded];
 };
 if(animated)[UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseInOut|UIViewAnimationOptionBeginFromCurrentState animations:changes completion:nil];
 else changes();
}
- (void)layoutSubviews{
 [super layoutSubviews];self.outerGlass.frame=self.bounds;
 CGFloat width=CGRectGetWidth(self.bounds),height=CGRectGetHeight(self.bounds);if(width<=0||height<=0)return;
 CGFloat cell=width/MAX((CGFloat)self.buttons.count,1.0);CGFloat verticalInset=MAX(3.0,MIN(5.0,height*0.08));CGFloat horizontalInset=2.0;
 for(UIButton *button in self.buttons){
  CGFloat x=cell*button.tag+horizontalInset;
  button.frame=CGRectMake(x,verticalInset,MAX(0,cell-horizontalInset*2),MAX(0,height-verticalInset*2));
 }
}
@end

static void GSCollectVisibleLabels(UIView *view,UIControl *segments,NSMutableArray<NSDictionary *> *items){
 if(view!=segments&&(view.hidden||view.alpha<=0.01))return;
 if([view isKindOfClass:UILabel.class]){
  NSString *text=((UILabel *)view).text;
  if(text.length&&text.length<48){
   CGPoint center=[view convertPoint:CGPointMake(CGRectGetMidX(view.bounds),CGRectGetMidY(view.bounds)) toView:segments];
   [items addObject:@{@"title":text,@"x":@(center.x)}];
  }
 }
 for(UIView *child in view.subviews)GSCollectVisibleLabels(child,segments,items);
}

static void GSCollectAccessibilityLabels(UIView *view,NSMutableArray<NSString *> *labels){
 NSString *label=view.accessibilityLabel;
 if(view.isAccessibilityElement&&label.length&&label.length<48&&![labels containsObject:label]&&
    [label rangeOfString:@"Search" options:NSCaseInsensitiveSearch].location==NSNotFound)[labels addObject:label];
 for(UIView *child in view.subviews)GSCollectAccessibilityLabels(child,labels);
}

static NSArray<NSString *> *GSTabTitles(UIControl *segments){
 NSMutableArray<NSDictionary *> *items=[NSMutableArray array];GSCollectVisibleLabels(segments,segments,items);
 [items sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"x"] compare:b[@"x"]];}];
 NSMutableArray<NSString *> *titles=[NSMutableArray arrayWithCapacity:3];
 for(NSDictionary *item in items){NSString *title=item[@"title"];if(![titles containsObject:title])[titles addObject:title];if(titles.count==3)break;}
 if(titles.count<3){
  NSMutableArray<NSString *> *accessible=[NSMutableArray array];GSCollectAccessibilityLabels(segments,accessible);
  for(NSString *title in accessible){if(![titles containsObject:title])[titles addObject:title];if(titles.count==3)break;}
 }
 if(titles.count==3)return titles;
 return @[ @"Photos",@"Collections",@"Create"];
}

static void GSSyncTabSelection(GSPhotosGlassPair *pair){
 if(!pair.tabProxy||!pair.segments)return;
 NSInteger selected=GSInteger(pair.segments,@"selectedSegmentIndex");
 if(selected>=0&&selected<(NSInteger)pair.tabProxy.buttons.count&&pair.tabProxy.selectedIndex!=selected)[pair.tabProxy setSelectedIndex:selected animated:NO];
}

static GSPhotosGlassTabView *GSCreateNativeTabProxy(GSPhotosGlassPair *pair){
 NSArray<NSString *> *titles=GSTabTitles(pair.segments);
 NSArray<NSString *> *symbols=@[ @"photo.on.rectangle.angled",@"rectangle.stack",@"plus.circle"];
 GSPhotosGlassTabView *view=[[GSPhotosGlassTabView alloc]initWithTitles:titles symbols:symbols owner:pair];
 NSInteger selected=GSInteger(pair.segments,@"selectedSegmentIndex");
 if(selected>=0&&selected<(NSInteger)view.buttons.count)[view setSelectedIndex:selected animated:NO];
 return view;
}

static UIButton *GSCreateNativeSearchButton(GSPhotosGlassPair *pair){
 Class configurationClass=NSClassFromString(@"UIButtonConfiguration");SEL selector=NSSelectorFromString(@"glassButtonConfiguration");
 if(![configurationClass respondsToSelector:selector])return nil;
 UIButtonConfiguration *configuration=((id(*)(id,SEL))objc_msgSend)(configurationClass,selector);
 if(![configuration isKindOfClass:UIButtonConfiguration.class])return nil;
 configuration.image=[UIImage systemImageNamed:@"magnifyingglass"]?:[pair.search imageForState:UIControlStateNormal];
 configuration.baseForegroundColor=UIColor.labelColor;configuration.cornerStyle=UIButtonConfigurationCornerStyleCapsule;
 UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.configuration=configuration;button.clipsToBounds=NO;
 button.accessibilityLabel=pair.search.accessibilityLabel?:@"Search";button.accessibilityHint=pair.search.accessibilityHint;
 button.accessibilityIdentifier=pair.search.accessibilityIdentifier;button.accessibilityTraits=pair.search.accessibilityTraits|UIAccessibilityTraitButton;
 [button addTarget:pair action:@selector(searchPressed:) forControlEvents:UIControlEventTouchUpInside];
 return button;
}

static void GSRestore(GSPhotosGlassPair *pair){
 if(!pair||pair.changing)return;
 pair.changing=YES;
 for(id object in @[pair.controller?:NSNull.null,pair.segments?:NSNull.null,pair.search?:NSNull.null])
  if(object!=NSNull.null&&objc_getAssociatedObject(object,&GSGlassPairKey)==pair)objc_setAssociatedObject(object,&GSGlassPairKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
 [pair.tabProxy removeFromSuperview];[pair.searchProxy removeFromSuperview];
 pair.segments.alpha=pair.segmentsAlpha;pair.segments.userInteractionEnabled=pair.segmentsInteraction;pair.segments.accessibilityElementsHidden=pair.segmentsAccessibilityHidden;
 pair.search.alpha=pair.searchAlpha;pair.search.userInteractionEnabled=pair.searchInteraction;pair.search.accessibilityElementsHidden=pair.searchAccessibilityHidden;
 [GSPairs removeObject:pair];pair.changing=NO;
}

static BOOL GSLayoutNativeControls(GSPhotosGlassPair *pair){
 if(!pair||pair.changing)return NO;
 if(!pair.host||pair.host!=pair.bar||!pair.bar.superview||pair.segments.superview!=pair.bar||pair.search.superview!=pair.bar||
    ![pair.bar.arrangedSubviews containsObject:pair.segments]||![pair.bar.arrangedSubviews containsObject:pair.search]||
    pair.tabProxy.superview!=pair.host||pair.searchProxy.superview!=pair.host){GSRestore(pair);GSLastSkip=@"bottom_bar_hierarchy_changed";return NO;}
 pair.changing=YES;[pair.bar layoutIfNeeded];
 pair.segments.alpha=0;pair.segments.userInteractionEnabled=NO;pair.segments.accessibilityElementsHidden=YES;
 pair.search.alpha=0;pair.search.userInteractionEnabled=NO;pair.search.accessibilityElementsHidden=YES;
 CGRect tabFrame=[pair.segments convertRect:pair.segments.bounds toView:pair.host];
 CGRect searchFrame=[pair.search convertRect:pair.search.bounds toView:pair.host];
 // The old UITabBarController experiment had a full-height frame but its private
 // platter kept compact metrics, producing the thin pill in device screenshots.
 // Render the public glass capsule itself at the Search control's actual height.
 CGFloat targetHeight=MAX(CGRectGetHeight(searchFrame),56.0);
 tabFrame.origin.y=CGRectGetMidY(searchFrame)-targetHeight*0.5;tabFrame.size.height=targetHeight;
 pair.tabProxy.frame=tabFrame;pair.tabProxy.hidden=NO;pair.tabProxy.alpha=1;[pair.tabProxy setNeedsLayout];[pair.tabProxy layoutIfNeeded];
 pair.searchProxy.frame=searchFrame;pair.searchProxy.hidden=NO;pair.searchProxy.alpha=1;
 GSSyncTabSelection(pair);[pair.host bringSubviewToFront:pair.tabProxy];[pair.host bringSubviewToFront:pair.searchProxy];
 pair.changing=NO;return YES;
}

@implementation GSPhotosGlassPair
- (void)tabPressed:(UIButton *)sender{
 if(self.changing||![self.tabProxy.buttons containsObject:sender]||!self.segments)return;
 NSInteger index=sender.tag,before=GSInteger(self.segments,@"selectedSegmentIndex");
 if(index<0||index>=GSInteger(self.segments,@"numberOfSegments")||index==before)return;
 GSPhotosGlassValueChangeProbe *probe=[GSPhotosGlassValueChangeProbe new];
 [(UIControl *)self.segments addTarget:probe action:@selector(valueChanged:) forControlEvents:UIControlEventValueChanged];
 self.changing=YES;GSSetInteger(self.segments,@"setSelectedSegmentIndex:",index);self.changing=NO;
 [(UIControl *)self.segments removeTarget:probe action:@selector(valueChanged:) forControlEvents:UIControlEventValueChanged];
 NSInteger after=GSInteger(self.segments,@"selectedSegmentIndex");
 if(after!=before&&after==index&&!probe.fired)[(UIControl *)self.segments sendActionsForControlEvents:UIControlEventValueChanged];
 [self.tabProxy setSelectedIndex:after animated:YES];
}
- (void)searchPressed:(UIButton *)sender{
 if(self.changing||sender!=self.searchProxy||!self.search)return;
 [self.search sendActionsForControlEvents:UIControlEventTouchUpInside];
}
@end

static void GSUpdateController(UIViewController *controller){
 [GSControllers addObject:controller];
 GSPhotosGlassPair *previous=objc_getAssociatedObject(controller,&GSGlassPairKey);
 if(!GSPhotosGlassActiveThisLaunch()){GSRestore(previous);return;}
 if(previous.changing)return;
 UIStackView *bar=GSGet(controller,@"floatingBottomTabBar");
 UIControl *segments=GSGet(controller,@"floatingSegmentedControl");
 UIButton *search=GSGet(controller,@"floatingSearchButton");
 if(previous&&previous.bar==bar&&previous.segments==segments&&previous.search==search){GSLayoutNativeControls(previous);return;}
 GSRestore(previous);
 if(![bar isKindOfClass:UIStackView.class]||![segments isKindOfClass:UIControl.class]||![segments isKindOfClass:NSClassFromString(@"PHSSegmentedControl")]||
    ![search isKindOfClass:UIButton.class]||![search isKindOfClass:NSClassFromString(@"M3CButton")]||!bar.superview||
    segments.superview!=bar||search.superview!=bar||![bar.arrangedSubviews containsObject:segments]||![bar.arrangedSubviews containsObject:search]){GSLastSkip=@"floating_bottom_bar_not_found";return;}
 if(GSInteger(segments,@"numberOfSegments")!=3){GSLastSkip=@"unexpected_segment_count";return;}
 if(objc_getAssociatedObject(segments,&GSGlassPairKey)||objc_getAssociatedObject(search,&GSGlassPairKey)){GSLastSkip=@"bottom_bar_already_owned";return;}
 GSPhotosGlassPair *pair=[GSPhotosGlassPair new];pair.controller=controller;pair.bar=bar;pair.host=bar;pair.segments=segments;pair.search=search;
 pair.segmentsAlpha=segments.alpha;pair.searchAlpha=search.alpha;pair.segmentsInteraction=segments.userInteractionEnabled;pair.searchInteraction=search.userInteractionEnabled;
 pair.segmentsAccessibilityHidden=segments.accessibilityElementsHidden;pair.searchAccessibilityHidden=search.accessibilityElementsHidden;
 pair.tabProxy=GSCreateNativeTabProxy(pair);pair.searchProxy=GSCreateNativeSearchButton(pair);
 if(!pair.tabProxy||!pair.searchProxy){GSLastSkip=@"native_control_creation_failed";return;}
 for(id object in @[controller,segments,search])objc_setAssociatedObject(object,&GSGlassPairKey,pair,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
 [GSPairs addObject:pair];[pair.host addSubview:pair.tabProxy];[pair.host addSubview:pair.searchProxy];
 if(GSLayoutNativeControls(pair))GSLastSkip=nil;
}

static void GSVisitController(UIViewController *controller,NSMutableSet *seen){
 if(!controller||[seen containsObject:controller])return;[seen addObject:controller];
 if(controller.isViewLoaded&&[controller isKindOfClass:NSClassFromString(@"PHSTabBarController")])GSUpdateController(controller);
 for(UIViewController *child in controller.childViewControllers)GSVisitController(child,seen);GSVisitController(controller.presentedViewController,seen);
}
static void GSDiscoverControllers(void){
 if(!GSInstalled)return;NSMutableSet *seen=[NSMutableSet set];
 for(UIScene *scene in UIApplication.sharedApplication.connectedScenes)if([scene isKindOfClass:UIWindowScene.class])for(UIWindow *window in ((UIWindowScene *)scene).windows)GSVisitController(window.rootViewController,seen);
}
static void GSHook(Class cls,NSString *name,IMP replacement){SEL selector=NSSelectorFromString(name);Method method=class_getInstanceMethod(cls,selector);class_replaceMethod(cls,selector,replacement,method_getTypeEncoding(method));}
void GSInstallPhotosGlass(void){
 if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{GSInstallPhotosGlass();});return;}
 if(GSInstalled||!GSPhotosGlassAvailable())return;GSControllers=NSHashTable.weakObjectsHashTable;GSPairs=NSHashTable.weakObjectsHashTable;
 Class cls=NSClassFromString(@"PHSTabBarController");SEL controllerLayoutSel=@selector(viewDidLayoutSubviews);IMP controllerLayout=method_getImplementation(class_getInstanceMethod(cls,controllerLayoutSel));
 GSHook(cls,@"viewDidLayoutSubviews",imp_implementationWithBlock(^(UIViewController *controller){((void(*)(id,SEL))controllerLayout)(controller,controllerLayoutSel);GSUpdateController(controller);}));
 cls=NSClassFromString(@"PHSSegmentedControl");SEL segmentLayoutSel=@selector(layoutSubviews);IMP segmentLayout=method_getImplementation(class_getInstanceMethod(cls,segmentLayoutSel));
 GSHook(cls,@"layoutSubviews",imp_implementationWithBlock(^(UIView *view){((void(*)(id,SEL))segmentLayout)(view,segmentLayoutSel);GSLayoutNativeControls(objc_getAssociatedObject(view,&GSGlassPairKey));}));
 SEL setIndexSel=NSSelectorFromString(@"setSelectedSegmentIndex:");IMP setIndex=method_getImplementation(class_getInstanceMethod(cls,setIndexSel));
 GSHook(cls,@"setSelectedSegmentIndex:",imp_implementationWithBlock(^(id control,NSInteger index){((void(*)(id,SEL,NSInteger))setIndex)(control,setIndexSel,index);GSPhotosGlassPair *pair=objc_getAssociatedObject(control,&GSGlassPairKey);if(pair&&!pair.changing)GSSyncTabSelection(pair);}));
 cls=NSClassFromString(@"M3CButton");SEL buttonLayoutSel=@selector(layoutSubviews);IMP buttonLayout=method_getImplementation(class_getInstanceMethod(cls,buttonLayoutSel));
 GSHook(cls,@"layoutSubviews",imp_implementationWithBlock(^(UIView *button){((void(*)(id,SEL))buttonLayout)(button,buttonLayoutSel);GSLayoutNativeControls(objc_getAssociatedObject(button,&GSGlassPairKey));}));
 GSInstalled=YES;GSDiscoverControllers();
}
void GSSetPhotosGlass(BOOL enabled){
 if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{GSSetPhotosGlass(enabled);});return;}
 GSInstallPhotosGlass();if(enabled&&!GSInstalled)return;[NSUserDefaults.standardUserDefaults setBool:enabled forKey:GSPhotosGlassPreference];GSWriteDesignCompatibilityOverride(enabled);
 GSRestartRequired=enabled!=GSBootGlassEnabled;GSLastSkip=GSRestartRequired?@"restart_required":nil;
 if(!enabled||GSRestartRequired)for(GSPhotosGlassPair *pair in GSPairs.allObjects)GSRestore(pair);
 if(enabled&&!GSRestartRequired){GSDiscoverControllers();for(UIViewController *controller in GSControllers.allObjects)GSUpdateController(controller);}
}
NSDictionary *GSPhotosGlassSnapshot(void){
 if(!NSThread.isMainThread){__block NSDictionary *snapshot;dispatch_sync(dispatch_get_main_queue(),^{snapshot=GSPhotosGlassSnapshot();});return snapshot;}
 NSUInteger attached=0;for(GSPhotosGlassPair *pair in GSPairs.allObjects)if(pair.tabProxy.superview==pair.host&&pair.searchProxy.superview==pair.host&&pair.segments.superview==pair.bar&&pair.search.superview==pair.bar)attached++;
 NSString *unavailable=GSUnavailableReason();
 return @{@"enabled":@(GSPhotosGlassEnabled()),@"activeThisLaunch":@(GSPhotosGlassActiveThisLaunch()),@"available":@(unavailable==nil),@"hooksInstalled":@(GSInstalled),
  @"designCompatibilityOverride":@(GSDesignOverrideApplied),@"restartRequired":@(GSRestartRequired),@"controllersSeen":@(GSControllers.count),@"attachedBars":@(attached),
  @"reason":unavailable?:(GSRestartRequired?@"restart_required":attached?@"attached":GSLastSkip?:(GSPhotosGlassEnabled()?@"waiting_for_bottom_bar":@"disabled")),@"lastSkipReason":GSLastSkip?:NSNull.null};
}
__attribute__((constructor)) static void GSLoadPhotosGlass(void){
 @autoreleasepool{
  GSBootGlassEnabled=[NSUserDefaults.standardUserDefaults boolForKey:GSDesignCompatibilityOverride];GSDesignOverrideApplied=GSBootGlassEnabled;
  if(!GSPhotosHostSupported())return;
  GSBootGlassEnabled=GSPhotosGlassEnabled()&&GSPhotosGlassHostVersionSupported();GSWriteDesignCompatibilityOverride(GSBootGlassEnabled);GSDesignOverrideApplied=GSBootGlassEnabled;
  [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){GSInstallPhotosGlass();GSDiscoverControllers();}];
  dispatch_async(dispatch_get_main_queue(),^{GSInstallPhotosGlass();});
 }
}
