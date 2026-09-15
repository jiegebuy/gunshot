// Included by the existing settings UIKit smoke. The production feature finds
// these classes by their Google Photos runtime names, so keep the fake surface
// limited to the audited native contracts in GSPhotosGlass.m.
#import "../UI/GSPhotosGlass.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include <math.h>
#include <string.h>

static UIColor *GSFixtureSegmentColor(void){return [UIColor colorWithRed:0.94 green:0.94 blue:0.96 alpha:1.0];}
static UIColor *GSFixtureShadowColor(void){return [UIColor colorWithRed:0.86 green:0.86 blue:0.89 alpha:1.0];}
static UIColor *GSFixtureContentColor(void){return [UIColor colorWithRed:0.98 green:0.98 blue:0.99 alpha:1.0];}
static UIColor *GSFixtureThemeSegmentColor(void){return [UIColor colorWithRed:0.91 green:0.95 blue:1.0 alpha:1.0];}
static UIColor *GSFixtureThemeShadowColor(void){return [UIColor colorWithRed:0.82 green:0.89 blue:0.98 alpha:1.0];}
static UIColor *GSFixtureThemeContentColor(void){return [UIColor colorWithRed:0.95 green:0.97 blue:1.0 alpha:1.0];}
static UIColor *GSFixtureSearchColor(void){return [UIColor colorWithRed:0.93 green:0.93 blue:0.95 alpha:1.0];}
static UIColor *GSFixtureBrandNormalColor(void){return [UIColor colorWithRed:0.90 green:0.90 blue:0.92 alpha:1.0];}
static UIColor *GSFixtureBrandHighlightColor(void){return [UIColor colorWithRed:0.84 green:0.84 blue:0.87 alpha:1.0];}
static UIColor *GSFixtureBrandTintColor(void){return [UIColor colorWithRed:0.20 green:0.20 blue:0.22 alpha:1.0];}
static id GSFixtureBrandShadow(void){return @"brand-shadow";}
static UIColor *GSFixturePhotosNormalColor(void){return [UIColor colorWithRed:0.88 green:0.93 blue:1.0 alpha:1.0];}
static UIColor *GSFixturePhotosHighlightColor(void){return [UIColor colorWithRed:0.78 green:0.87 blue:0.99 alpha:1.0];}
static UIColor *GSFixturePhotosTintColor(void){return [UIColor colorWithRed:0.08 green:0.36 blue:0.86 alpha:1.0];}
static id GSFixturePhotosShadow(void){return @"photos-search-shadow";}

@interface PHSShadowView : UIView {
 double _elevation;
 _Bool _adaptiveBackgroundColorEnabled;
}
@property(nonatomic) double elevation;
@property(nonatomic) _Bool adaptiveBackgroundColorEnabled;
- (double)mdc_currentElevation;
@end
@implementation PHSShadowView
- (double)elevation{return _elevation;}
- (void)setElevation:(double)value{_elevation=value;}
- (double)mdc_currentElevation{return _elevation;}
- (_Bool)adaptiveBackgroundColorEnabled{return _adaptiveBackgroundColorEnabled;}
- (void)setAdaptiveBackgroundColorEnabled:(_Bool)value{_adaptiveBackgroundColorEnabled=value;}
@end

@interface PHSSegmentedControl : UIControl {
 NSInteger _selectedSegmentIndex;
}
@property(nonatomic,strong) PHSShadowView *shadow;
@property(nonatomic,strong) UIView *content;
@property(nonatomic,strong) UIView *selection;
@property(nonatomic) NSInteger selectedSegmentIndex;
@property(nonatomic) NSUInteger themeUpdates;
- (NSInteger)numberOfSegments;
@end
@implementation PHSSegmentedControl
- (instancetype)initWithFrame:(CGRect)frame{
 if((self=[super initWithFrame:frame])){
  self.backgroundColor=GSFixtureSegmentColor();self.opaque=YES;self.clipsToBounds=YES;
  self.shadow=[[PHSShadowView alloc]initWithFrame:self.bounds];self.shadow.backgroundColor=GSFixtureShadowColor();self.shadow.opaque=YES;
  self.shadow.adaptiveBackgroundColorEnabled=YES;self.shadow.elevation=3;
  self.content=[[UIView alloc]initWithFrame:self.bounds];self.content.backgroundColor=GSFixtureContentColor();self.content.opaque=YES;
  self.content.accessibilityTraits=UIAccessibilityTraitTabBar;
  self.selection=[[UIView alloc]initWithFrame:CGRectMake(4,4,80,48)];self.selection.backgroundColor=UIColor.tertiarySystemFillColor;
  [self addSubview:self.shadow];[self.shadow addSubview:self.content];[self.content addSubview:self.selection];
  NSArray *titles=@[@"Photos",@"Collections",@"Create"];
  for(NSInteger i=0;i<3;i++){
   UILabel *label=[[UILabel alloc]initWithFrame:CGRectMake(8+i*84,8,76,40)];label.text=titles[i];label.textAlignment=NSTextAlignmentCenter;
   [self.content addSubview:label];
  }
 }
 return self;
}
- (NSInteger)numberOfSegments{return 3;}
- (NSInteger)selectedSegmentIndex{return _selectedSegmentIndex;}
- (void)setSelectedSegmentIndex:(NSInteger)value{
 if(_selectedSegmentIndex==value)return;
 _selectedSegmentIndex=value;
 [self sendActionsForControlEvents:UIControlEventValueChanged];
}
- (void)layoutSubviews{
 [super layoutSubviews];self.shadow.frame=self.bounds;self.content.frame=self.shadow.bounds;
 self.selection.frame=CGRectMake(4,4,MIN(80,MAX(0,self.content.bounds.size.width-8)),MAX(0,self.content.bounds.size.height-8));
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous{
 [super traitCollectionDidChange:previous];self.themeUpdates++;
 self.backgroundColor=GSFixtureThemeSegmentColor();self.opaque=YES;
 self.shadow.backgroundColor=GSFixtureThemeShadowColor();self.shadow.opaque=YES;
 self.content.backgroundColor=GSFixtureThemeContentColor();self.content.opaque=YES;
}
@end

@interface M3CMaterialGlassEffect : NSObject
@property(nonatomic) NSInteger type;
@property(nonatomic) CGFloat backgroundOpacity;
@property(nonatomic,strong) UIColor *tintColor;
@end
@implementation M3CMaterialGlassEffect
- (instancetype)init{if((self=[super init])){self.backgroundOpacity=1.0;self.tintColor=GSFixtureSearchColor();}return self;}
@end

@interface M3CMaterialGlassEffectView : UIVisualEffectView
@property(nonatomic,strong) M3CMaterialGlassEffect *glass;
@property(nonatomic) NSInteger lastRequestedStyle;
- (_Bool)isGlass;
- (void)updateGlassEffect;
@end
@implementation M3CMaterialGlassEffectView
- (_Bool)isGlass{return NO;}
- (void)updateGlassEffect{
 if([self isGlass]&&self.glass.type!=0){
  self.lastRequestedStyle=self.glass.type==1?1:0;
  id glass=((id(*)(id,SEL,NSInteger))objc_msgSend)(NSClassFromString(@"UIGlassEffect"),NSSelectorFromString(@"effectWithStyle:"),self.lastRequestedStyle);
  self.effect=[glass isKindOfClass:UIVisualEffect.class]?glass:nil;
 }else{self.lastRequestedStyle=-1;self.effect=nil;}
}
@end

@interface M3CButton : UIButton
@property(nonatomic,strong) M3CMaterialGlassEffectView *glassEffectView;
@property(nonatomic) NSInteger glassType;
@property(nonatomic) NSUInteger normalBrandCalls;
@property(nonatomic) NSUInteger glassBrandCalls;
@property(nonatomic) NSUInteger glassBrandNormalPasses;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,id> *fixtureBackgroundColors;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,id> *fixtureShadows;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,id> *fixtureTintColors;
- (_Bool)isGlassEnabled;
- (void)phs_brandIconTonalRound;
- (void)phs_brandIconTonalGlassRound;
- (id)backgroundColorForState:(NSUInteger)state;
- (void)setBackgroundColor:(id)value forState:(NSUInteger)state;
- (id)shadowForState:(NSUInteger)state;
- (void)setShadow:(id)value forState:(NSUInteger)state;
- (id)tintColorForState:(NSUInteger)state;
- (void)setTintColor:(id)value forState:(NSUInteger)state;
@end
static void GSFixtureApplyNormalSearchStyle(M3CButton *button){
 button.glassType=0;button.backgroundColor=GSFixtureSearchColor();button.opaque=YES;button.layer.shadowOpacity=0.24f;
 [button setBackgroundColor:GSFixtureBrandNormalColor() forState:UIControlStateNormal];
 [button setBackgroundColor:GSFixtureBrandHighlightColor() forState:UIControlStateHighlighted];
 [button setShadow:GSFixtureBrandShadow() forState:UIControlStateNormal];
 [button setTintColor:GSFixtureBrandTintColor() forState:UIControlStateNormal];
 button.glassEffectView.glass.backgroundOpacity=1.0;button.glassEffectView.glass.tintColor=GSFixtureSearchColor();
 [button.glassEffectView updateGlassEffect];
}
@implementation M3CButton
- (instancetype)initWithFrame:(CGRect)frame{
 if((self=[super initWithFrame:frame])){
  self.fixtureBackgroundColors=[NSMutableDictionary dictionary];self.fixtureShadows=[NSMutableDictionary dictionary];self.fixtureTintColors=[NSMutableDictionary dictionary];
  self.backgroundColor=GSFixtureSearchColor();self.opaque=YES;self.layer.shadowOpacity=0.24f;
  self.glassEffectView=[[M3CMaterialGlassEffectView alloc]initWithEffect:nil];
  self.glassEffectView.glass=[M3CMaterialGlassEffect new];self.glassEffectView.userInteractionEnabled=NO;
  [self insertSubview:self.glassEffectView atIndex:0];
 }
 return self;
}
- (void)layoutSubviews{[super layoutSubviews];self.glassEffectView.frame=self.bounds;}
- (NSInteger)glassType{return self.glassEffectView.glass.type;}
- (void)setGlassType:(NSInteger)value{self.glassEffectView.glass.type=value;}
- (id)backgroundColorForState:(NSUInteger)state{return self.fixtureBackgroundColors[@(state)];}
- (void)setBackgroundColor:(id)value forState:(NSUInteger)state{if(value)self.fixtureBackgroundColors[@(state)]=value;else [self.fixtureBackgroundColors removeObjectForKey:@(state)];}
- (id)shadowForState:(NSUInteger)state{return self.fixtureShadows[@(state)];}
- (void)setShadow:(id)value forState:(NSUInteger)state{if(value)self.fixtureShadows[@(state)]=value;else [self.fixtureShadows removeObjectForKey:@(state)];}
- (id)tintColorForState:(NSUInteger)state{return self.fixtureTintColors[@(state)];}
- (void)setTintColor:(id)value forState:(NSUInteger)state{if(value)self.fixtureTintColors[@(state)]=value;else [self.fixtureTintColors removeObjectForKey:@(state)];}
- (_Bool)isGlassEnabled{return NO;}
- (void)phs_brandIconTonalRound{self.normalBrandCalls++;GSFixtureApplyNormalSearchStyle(self);}
- (void)phs_brandIconTonalGlassRound{
 self.glassBrandCalls++;GSFixtureApplyNormalSearchStyle(self);self.glassBrandNormalPasses++;self.glassType=1;
 if([self isGlassEnabled]&&[self.glassEffectView isGlass]){
  self.backgroundColor=UIColor.clearColor;self.opaque=NO;self.layer.shadowOpacity=0;
  self.glassEffectView.glass.backgroundOpacity=0.18;
  self.glassEffectView.glass.tintColor=[UIColor colorWithWhite:1 alpha:0.12];
 }
 [self.glassEffectView updateGlassEffect];
}
@end

@interface PHSTabBarController : UIViewController
@property(nonatomic,strong) UIStackView *floatingBottomTabBar;
@property(nonatomic,strong) PHSSegmentedControl *floatingSegmentedControl;
@property(nonatomic,strong) M3CButton *floatingSearchButton;
@property(nonatomic,strong) UITapGestureRecognizer *fixtureGesture;
@property(nonatomic) NSUInteger taps;
@end
@implementation PHSTabBarController
- (void)tap:(id)sender{self.taps++;}
- (void)gestureTap:(UITapGestureRecognizer *)gesture{self.taps++;}
- (void)viewDidLoad{
 [super viewDidLoad];self.view.backgroundColor=UIColor.systemBackgroundColor;
 self.floatingSegmentedControl=[[PHSSegmentedControl alloc]initWithFrame:CGRectMake(0,0,260,48)];
 self.floatingSearchButton=[[M3CButton alloc]initWithFrame:CGRectMake(0,0,56,56)];
 [self.floatingSearchButton phs_brandIconTonalRound];
 [self.floatingSearchButton setShadow:GSFixturePhotosShadow() forState:UIControlStateNormal];
 [self.floatingSearchButton setBackgroundColor:GSFixturePhotosNormalColor() forState:UIControlStateNormal];
 [self.floatingSearchButton setBackgroundColor:GSFixturePhotosHighlightColor() forState:UIControlStateHighlighted];
 [self.floatingSearchButton setTintColor:GSFixturePhotosTintColor() forState:UIControlStateNormal];
 self.floatingSearchButton.accessibilityLabel=@"Search";
 [self.floatingSearchButton setImage:[UIImage systemImageNamed:@"magnifyingglass"] forState:UIControlStateNormal];
 [self.floatingSearchButton addTarget:self action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
 [self.floatingSegmentedControl addTarget:self action:@selector(tap:) forControlEvents:UIControlEventValueChanged];
 self.fixtureGesture=[[UITapGestureRecognizer alloc]initWithTarget:self action:@selector(gestureTap:)];
 [self.floatingSearchButton addGestureRecognizer:self.fixtureGesture];
 self.floatingBottomTabBar=[[UIStackView alloc]initWithArrangedSubviews:@[self.floatingSegmentedControl,self.floatingSearchButton]];
 self.floatingBottomTabBar.axis=UILayoutConstraintAxisHorizontal;self.floatingBottomTabBar.spacing=12;
 [self.view addSubview:self.floatingBottomTabBar];
}
- (void)viewDidLayoutSubviews{
 [super viewDidLayoutSubviews];
 CGFloat width=MIN(MAX(220,self.view.bounds.size.width-32),360);
 self.floatingBottomTabBar.frame=CGRectMake(16,MAX(0,self.view.bounds.size.height-76),width,60);
 self.floatingSegmentedControl.frame=CGRectMake(0,6,MAX(120,width-72),48);
 self.floatingSearchButton.frame=CGRectMake(MAX(0,width-60),2,56,56);
 [self.floatingSegmentedControl layoutIfNeeded];[self.floatingSearchButton layoutIfNeeded];
}
@end

static id (*GSOriginalBundleInfo)(id,SEL,id);
static id GSFixturePhotosVersion;
static id GSGlassBundleInfo(id bundle,SEL selector,id key){
 if(bundle==NSBundle.mainBundle){
  if([key isEqual:@"CFBundleExecutable"])return @"GooglePhotos";
  if([key isEqual:@"CFBundleShortVersionString"])return GSFixturePhotosVersion;
 }
 return GSOriginalBundleInfo(bundle,selector,key);
}

static BOOL GSFixtureABI(Class cls,NSString *name,const char *abi){
 Method method=class_getInstanceMethod(cls,NSSelectorFromString(name));
 return method&&!strcmp(method_getTypeEncoding(method),abi);
}
static BOOL GSFixturePhotosGlassContracts(void){
 for(NSArray *entry in @[
  @[@"PHSTabBarController",@"viewDidLayoutSubviews",@"v16@0:8"],
  @[@"PHSTabBarController",@"floatingBottomTabBar",@"@16@0:8"],
  @[@"PHSTabBarController",@"floatingSegmentedControl",@"@16@0:8"],
  @[@"PHSTabBarController",@"floatingSearchButton",@"@16@0:8"],
  @[@"PHSSegmentedControl",@"layoutSubviews",@"v16@0:8"],
  @[@"PHSSegmentedControl",@"numberOfSegments",@"q16@0:8"],
  @[@"PHSSegmentedControl",@"selectedSegmentIndex",@"q16@0:8"],
  @[@"PHSSegmentedControl",@"setSelectedSegmentIndex:",@"v24@0:8q16"],
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
  @[@"M3CButton",@"setBackgroundColor:forState:",@"v32@0:8@16Q24"],
  @[@"M3CButton",@"shadowForState:",@"@24@0:8Q16"],
  @[@"M3CButton",@"setShadow:forState:",@"v32@0:8@16Q24"],
  @[@"M3CButton",@"tintColorForState:",@"@24@0:8Q16"],
  @[@"M3CButton",@"setTintColor:forState:",@"v32@0:8@16Q24"],
  @[@"M3CMaterialGlassEffectView",@"isGlass",@"B16@0:8"],
  @[@"M3CMaterialGlassEffectView",@"glass",@"@16@0:8"],
  @[@"M3CMaterialGlassEffectView",@"updateGlassEffect",@"v16@0:8"],
  @[@"M3CMaterialGlassEffect",@"type",@"q16@0:8"]])
  if(!GSFixtureABI(NSClassFromString(entry[0]),entry[1],[entry[2]UTF8String]))return NO;
 return YES;
}

static UIControl *GSFixtureGlassTabProxy(PHSTabBarController *controller){
 UIView *host=controller.floatingBottomTabBar;
 for(UIView *view in host.subviews)if([NSStringFromClass(view.class) isEqualToString:@"GSPhotosGlassTabView"])return (UIControl *)view;
 return nil;
}
static NSArray<UIButton *> *GSFixtureGlassTabButtons(UIControl *proxy){
 id value=[proxy valueForKey:@"buttons"];return [value isKindOfClass:NSArray.class]?value:nil;
}
static NSInteger GSFixtureGlassSelectedIndex(UIControl *proxy){return [[proxy valueForKey:@"selectedIndex"]integerValue];}
static UIVisualEffectView *GSFixtureOuterGlass(UIControl *proxy){
 id value=[proxy valueForKey:@"outerGlass"];return [value isKindOfClass:UIVisualEffectView.class]?value:nil;
}
static UIButton *GSFixtureNativeSearchProxy(PHSTabBarController *controller){
 UIView *host=controller.floatingBottomTabBar;
 for(UIView *view in host.subviews)if([view isKindOfClass:UIButton.class]&&view!=controller.floatingSearchButton&&
    [view.accessibilityLabel isEqual:controller.floatingSearchButton.accessibilityLabel])return (UIButton *)view;
 return nil;
}
static void GSFixtureAttach(PHSTabBarController *controller,UIWindow *window){
 UIViewController *root=window.rootViewController;[controller loadViewIfNeeded];
 controller.view.frame=CGRectMake(0,0,window.bounds.size.width,MIN(180,window.bounds.size.height));
 [controller.view setNeedsLayout];[controller.view layoutIfNeeded];
 [root addChildViewController:controller];[root.view addSubview:controller.view];[controller didMoveToParentViewController:root];
}
static void GSFixtureDetach(PHSTabBarController *controller){
 [controller willMoveToParentViewController:nil];[controller.view removeFromSuperview];[controller removeFromParentViewController];
}

#define GS_GLASS_CHECK(value) do{if(!(value)){NSLog(@"FAIL bottom glass: %s",#value);return NO;}}while(0)
static BOOL GSCheckPhotosGlass(GSPanel *panel,UIWindow *window){
 BOOL modern=NO;if(@available(iOS 26.0,*))modern=YES;
 Method info=class_getInstanceMethod(NSBundle.class,@selector(objectForInfoDictionaryKey:));
 GSOriginalBundleInfo=(void *)method_setImplementation(info,(IMP)GSGlassBundleInfo);
 @try{
  GS_GLASS_CHECK(GSFixturePhotosGlassContracts());
  for(id version in @[@"7.20.2",@"7.91.9",@"7.9.20",@"unknown",@"",@"7.92.0-beta",@"7.92.0.1",@42]){
   GSFixturePhotosVersion=version;GS_GLASS_CHECK(!GSPhotosGlassAvailable());
  }
  for(NSString *version in @[@"7.92",@"7.92.0",@"7.100.0",@"8.0.0"]){
   GSFixturePhotosVersion=version;GS_GLASS_CHECK(GSPhotosGlassAvailable()==modern);
  }
  GSFixturePhotosVersion=@"7.92.0";
  [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"GSPhotosBottomBarLiquidGlass"];

  UITableViewCell *cell=[panel tableView:panel.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:2 inSection:6]];
  UISwitch *toggle=(UISwitch *)cell.accessoryView;
  GS_GLASS_CHECK([cell.textLabel.text isEqual:@"Google Photos · Liquid Glass"]&&[toggle isKindOfClass:UISwitch.class]&&!toggle.on&&toggle.enabled==modern);
  if(!modern){GS_GLASS_CHECK(!GSPhotosGlassEnabled());return YES;}

  PHSTabBarController *controller=[PHSTabBarController new];GSFixtureAttach(controller,window);
  PHSSegmentedControl *segments=controller.floatingSegmentedControl;M3CButton *search=controller.floatingSearchButton;
  UIStackView *bar=controller.floatingBottomTabBar;UIView *selection=segments.selection;UIImage *glyph=[search imageForState:UIControlStateNormal];UITapGestureRecognizer *gesture=controller.fixtureGesture;
  NSArray *originalChildren=controller.childViewControllers.copy;
  id savedNormal=[search backgroundColorForState:UIControlStateNormal];
  id savedHighlight=[search backgroundColorForState:UIControlStateHighlighted];
  id savedTint=[search tintColorForState:UIControlStateNormal];id savedShadow=[search shadowForState:UIControlStateNormal];
  GS_GLASS_CHECK(!GSPhotosGlassEnabled()&&!GSFixtureGlassTabProxy(controller)&&!GSFixtureNativeSearchProxy(controller)&&search.superview==bar&&[bar.arrangedSubviews containsObject:search]);
  GS_GLASS_CHECK([search.allTargets containsObject:controller]&&[segments.allTargets containsObject:controller]&&[search.gestureRecognizers containsObject:gesture]);

  toggle.on=YES;[toggle sendActionsForControlEvents:UIControlEventValueChanged];
  GS_GLASS_CHECK(GSPhotosGlassEnabled());GSInstallPhotosGlass();GSInstallPhotosGlass();
  NSDictionary *snapshot=GSPhotosGlassSnapshot();
  GS_GLASS_CHECK([snapshot[@"available"]boolValue]&&[snapshot[@"hooksInstalled"]boolValue]&&[snapshot[@"attachedBars"]unsignedIntegerValue]>=1);
  GS_GLASS_CHECK([snapshot[@"designCompatibilityOverride"]boolValue]&&![snapshot[@"restartRequired"]boolValue]&&[snapshot[@"activeThisLaunch"]boolValue]);

  UIControl *tabProxy=GSFixtureGlassTabProxy(controller);NSArray<UIButton *> *buttons=GSFixtureGlassTabButtons(tabProxy);
  UIButton *searchProxy=GSFixtureNativeSearchProxy(controller);UIVisualEffectView *outerGlass=GSFixtureOuterGlass(tabProxy);UIView *host=bar;
  GS_GLASS_CHECK(tabProxy&&tabProxy.superview==host&&buttons.count==3&&outerGlass&&outerGlass.effect);
  GS_GLASS_CHECK(controller.childViewControllers.count==originalChildren.count&&[controller.childViewControllers isEqualToArray:originalChildren]);
  GS_GLASS_CHECK(![tabProxy isKindOfClass:UITabBar.class]&&![controller.childViewControllers.lastObject isKindOfClass:UITabBarController.class]);
  GS_GLASS_CHECK([buttons[0].accessibilityLabel isEqual:@"Photos"]&&[buttons[1].accessibilityLabel isEqual:@"Collections"]&&[buttons[2].accessibilityLabel isEqual:@"Create"]);
  GS_GLASS_CHECK(GSFixtureGlassSelectedIndex(tabProxy)==0&&buttons[0].selected&&!buttons[1].selected&&!buttons[2].selected);
  GS_GLASS_CHECK(searchProxy&&searchProxy.superview==host&&searchProxy.configuration&&searchProxy.configuration.image&&searchProxy.configuration.cornerStyle==UIButtonConfigurationCornerStyleCapsule);
  GS_GLASS_CHECK([searchProxy.accessibilityLabel isEqual:@"Search"]);
  GS_GLASS_CHECK(segments.alpha==0&&!segments.userInteractionEnabled&&segments.accessibilityElementsHidden&&search.alpha==0&&!search.userInteractionEnabled&&search.accessibilityElementsHidden);

  CGRect originalTab=[segments convertRect:segments.bounds toView:host],expectedSearch=[search convertRect:search.bounds toView:host];
  CGFloat expectedHeight=MAX(CGRectGetHeight(expectedSearch),56.0);
  CGRect expectedTab=originalTab;expectedTab.origin.y=CGRectGetMidY(expectedSearch)-expectedHeight*0.5;expectedTab.size.height=expectedHeight;
  GS_GLASS_CHECK(CGRectEqualToRect(tabProxy.frame,expectedTab)&&CGRectEqualToRect(searchProxy.frame,expectedSearch));
  GS_GLASS_CHECK(fabs(CGRectGetHeight(tabProxy.frame)-CGRectGetHeight(searchProxy.frame))<0.01);
  for(UIButton *button in buttons)GS_GLASS_CHECK(CGRectGetHeight(button.frame)>=CGRectGetHeight(tabProxy.bounds)-10.1);

  GS_GLASS_CHECK(search.glassType==0&&!search.glassEffectView.effect&&search.opaque&&[search.backgroundColor isEqual:GSFixtureSearchColor()]);
  GS_GLASS_CHECK([[search backgroundColorForState:UIControlStateNormal] isEqual:savedNormal]&&[[search backgroundColorForState:UIControlStateHighlighted] isEqual:savedHighlight]);
  GS_GLASS_CHECK([[search tintColorForState:UIControlStateNormal] isEqual:savedTint]&&[[search shadowForState:UIControlStateNormal] isEqual:savedShadow]);
  GS_GLASS_CHECK(segments.selection==selection&&selection.superview==segments.content&&[search imageForState:UIControlStateNormal]==glyph&&[search.accessibilityLabel isEqual:@"Search"]);
  GS_GLASS_CHECK([search.allTargets containsObject:controller]&&[segments.allTargets containsObject:controller]&&[search.gestureRecognizers containsObject:gesture]);

  NSUInteger taps=controller.taps;[buttons[2] sendActionsForControlEvents:UIControlEventTouchUpInside];[searchProxy sendActionsForControlEvents:UIControlEventTouchUpInside];
  GS_GLASS_CHECK(controller.taps==taps+2&&segments.selectedSegmentIndex==2&&GSFixtureGlassSelectedIndex(tabProxy)==2&&buttons[2].selected);
  taps=controller.taps;[buttons[2] sendActionsForControlEvents:UIControlEventTouchUpInside];GS_GLASS_CHECK(controller.taps==taps);

  segments.selectedSegmentIndex=1;
  GS_GLASS_CHECK(GSFixtureGlassSelectedIndex(tabProxy)==1&&buttons[1].selected&&segments.selection==selection&&search.superview==bar);
  [controller viewDidLayoutSubviews];[segments layoutSubviews];[search layoutSubviews];
  GS_GLASS_CHECK(GSFixtureGlassTabProxy(controller)==tabProxy&&GSFixtureNativeSearchProxy(controller)==searchProxy&&segments.alpha==0&&search.alpha==0);
  GS_GLASS_CHECK(controller.childViewControllers.count==originalChildren.count);

  PHSTabBarController *second=[PHSTabBarController new];GSFixtureAttach(second,window);GSSetPhotosGlass(YES);
  GS_GLASS_CHECK(GSFixtureGlassTabProxy(second)&&GSFixtureNativeSearchProxy(second)&&second.floatingSearchButton.superview==second.floatingBottomTabBar);
  GS_GLASS_CHECK([GSPhotosGlassSnapshot()[@"attachedBars"]unsignedIntegerValue]>=2);

  GSSetPhotosGlass(NO);GSSetPhotosGlass(NO);
  GS_GLASS_CHECK(!GSPhotosGlassEnabled()&&!GSFixtureGlassTabProxy(controller)&&!GSFixtureNativeSearchProxy(controller)&&!GSFixtureGlassTabProxy(second)&&!GSFixtureNativeSearchProxy(second));
  GS_GLASS_CHECK(segments.alpha==1&&segments.userInteractionEnabled&&!segments.accessibilityElementsHidden&&search.alpha==1&&search.userInteractionEnabled&&!search.accessibilityElementsHidden);
  GS_GLASS_CHECK(search.superview==bar&&[bar.arrangedSubviews containsObject:search]&&search.opaque&&[search.backgroundColor isEqual:GSFixtureSearchColor()]);
  GS_GLASS_CHECK([[search backgroundColorForState:UIControlStateNormal] isEqual:savedNormal]&&[[search backgroundColorForState:UIControlStateHighlighted] isEqual:savedHighlight]);
  GS_GLASS_CHECK([[search tintColorForState:UIControlStateNormal] isEqual:savedTint]&&[[search shadowForState:UIControlStateNormal] isEqual:savedShadow]);
  GS_GLASS_CHECK(segments.selection==selection&&[search imageForState:UIControlStateNormal]==glyph&&[search.gestureRecognizers containsObject:gesture]);
  snapshot=GSPhotosGlassSnapshot();GS_GLASS_CHECK(![snapshot[@"enabled"]boolValue]&&[snapshot[@"attachedBars"]unsignedIntegerValue]==0);

  PHSTabBarController *badSearch=[PHSTabBarController new];[badSearch loadViewIfNeeded];
  PHSSegmentedControl *badSegments=badSearch.floatingSegmentedControl;M3CButton *badButton=badSearch.floatingSearchButton;
  UIColor *badSegmentColor=badSegments.backgroundColor,*badButtonColor=badButton.backgroundColor;
  [badSearch.floatingBottomTabBar removeArrangedSubview:badButton];[badButton removeFromSuperview];[badSearch.view addSubview:badButton];
  GSSetPhotosGlass(YES);[badSearch viewDidLayoutSubviews];
  GS_GLASS_CHECK(!GSFixtureGlassTabProxy(badSearch)&&!GSFixtureNativeSearchProxy(badSearch)&&[badSegments.backgroundColor isEqual:badSegmentColor]&&badSegments.alpha==1);
  GS_GLASS_CHECK(badButton.opaque&&[badButton.backgroundColor isEqual:badButtonColor]);
  GSSetPhotosGlass(NO);

  PHSTabBarController *badSegmentsController=[PHSTabBarController new];[badSegmentsController loadViewIfNeeded];
  [badSegmentsController.floatingBottomTabBar removeArrangedSubview:badSegmentsController.floatingSegmentedControl];
  M3CButton *validSearch=badSegmentsController.floatingSearchButton;
  GSSetPhotosGlass(YES);[badSegmentsController viewDidLayoutSubviews];
  GS_GLASS_CHECK(!GSFixtureGlassTabProxy(badSegmentsController)&&!GSFixtureNativeSearchProxy(badSegmentsController)&&validSearch.opaque);
  GSSetPhotosGlass(NO);

  GSFixtureDetach(second);GSFixtureDetach(controller);
  NSLog(@"PASS thick public Liquid Glass tab proxy + glass Search, no foreign child controller, exact ABIs, single-fire navigation, untouched Google backends and restoration");
 } @finally {
  method_setImplementation(info,(IMP)GSOriginalBundleInfo);GSFixturePhotosVersion=nil;
 }
 GS_GLASS_CHECK(!GSPhotosGlassAvailable());
 return YES;
}
#undef GS_GLASS_CHECK
