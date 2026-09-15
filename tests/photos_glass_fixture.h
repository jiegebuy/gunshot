// Included by the existing settings UIKit smoke. The production feature finds
// these classes by their Google Photos runtime names, so keep the fake surface
// limited to the audited native contracts in GSPhotosGlass.m.
#import "../UI/GSPhotosGlass.h"
#import <objc/message.h>
#import <objc/runtime.h>
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

@interface PHSSegmentedControl : UIControl
@property(nonatomic,strong) PHSShadowView *shadow;
@property(nonatomic,strong) UIView *content;
@property(nonatomic,strong) UIView *selection;
@property(nonatomic) NSInteger selectedSegmentIndex;
@property(nonatomic) NSUInteger themeUpdates;
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
 }
 return self;
}
- (void)layoutSubviews{
 [super layoutSubviews];self.shadow.frame=self.bounds;self.content.frame=self.shadow.bounds;
 self.selection.frame=CGRectMake(4,4,MIN(80,MAX(0,self.content.bounds.size.width-8)),MAX(0,self.content.bounds.size.height-8));
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous{
 [super traitCollectionDidChange:previous];self.themeUpdates++;
 // Model the native theme pass painting opaque surfaces again. The production
 // hook must remember these colors, clear them for glass, then restore them on
 // opt-out without replacing the native hierarchy.
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
- (instancetype)init{
 if((self=[super init])){self.backgroundOpacity=1.0;self.tintColor=GSFixtureSearchColor();}
 return self;
}
@end

@interface M3CMaterialGlassEffectView : UIVisualEffectView
@property(nonatomic,strong) M3CMaterialGlassEffect *glass;
@property(nonatomic) NSInteger lastRequestedStyle;
- (_Bool)isGlass;
- (void)updateGlassEffect;
@end
@implementation M3CMaterialGlassEffectView
- (_Bool)isGlass{return NO;} // Google Photos 7.92 compatibility path on the fixture host.
- (void)updateGlassEffect{
 if([self isGlass]&&self.glass.type!=0){
  // Native 7.92 maps material type 1 to Clear (style 1) and type 2 to
  // Regular (style 0). Keep this explicit so the fixture catches regressions
  // that treat every nonzero type as the same material.
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
- (void)phs_brandIconTonalRound{
 self.normalBrandCalls++;GSFixtureApplyNormalSearchStyle(self);
}
- (void)phs_brandIconTonalGlassRound{
 self.glassBrandCalls++;
 // The native glass brand synchronously reapplies the ordinary tonal-round
 // state first, including material type 0, then transitions to glass type 1.
 // Use a plain helper here: calling phs_brandIconTonalRound would hit the
 // production hook while opted in and recurse back into this selector.
 GSFixtureApplyNormalSearchStyle(self);self.glassBrandNormalPasses++;self.glassType=1;
 // A type flip is not enough on the compatibility host. The real native brand
 // path also consults the two compatibility predicates before changing the
 // material/surface state; GSPhotosGlass only overrides them for its own pair.
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
 self.floatingSegmentedControl=[[PHSSegmentedControl alloc]initWithFrame:CGRectMake(0,0,260,56)];
 self.floatingSearchButton=[[M3CButton alloc]initWithFrame:CGRectMake(0,0,56,56)];
 [self.floatingSearchButton phs_brandIconTonalRound];
 // createFloatingSearchButton reapplies Photos-owned state values after the
 // generic brand. These must survive a glass round-trip exactly.
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
 self.floatingSegmentedControl.frame=CGRectMake(0,2,MAX(120,width-72),56);
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

static UIVisualEffectView *GSFixturePillEffect(PHSSegmentedControl *segments){
 for(UIView *view in segments.subviews)if([view isKindOfClass:UIVisualEffectView.class])return (UIVisualEffectView *)view;
 return nil;
}
static id GSFixtureCornerConfiguration(UIVisualEffectView *view){
 SEL selector=NSSelectorFromString(@"cornerConfiguration");
 return [view respondsToSelector:selector]?((id(*)(id,SEL))objc_msgSend)(view,selector):nil;
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

  // A plain native type change does not activate Liquid Glass on the compatibility
  // host. This is the failure mode that the production code must not mistake for
  // a successful search-button conversion.
  M3CButton *typeProbe=[[M3CButton alloc]initWithFrame:CGRectMake(0,0,56,56)];
  UIColor *probeColor=typeProbe.backgroundColor;typeProbe.glassType=1;[typeProbe.glassEffectView updateGlassEffect];
  GS_GLASS_CHECK(typeProbe.glassType==1&&![typeProbe isGlassEnabled]&&![typeProbe.glassEffectView isGlass]&&!typeProbe.glassEffectView.effect);
  GS_GLASS_CHECK(typeProbe.opaque&&[typeProbe.backgroundColor isEqual:probeColor]&&typeProbe.glassBrandCalls==0);
  GS_GLASS_CHECK(typeProbe.glassEffectView.glass.backgroundOpacity==1.0&&CGColorGetAlpha(typeProbe.glassEffectView.glass.tintColor.CGColor)==1.0);

  UITableViewCell *cell=[panel tableView:panel.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:2 inSection:6]];
  UISwitch *toggle=(UISwitch *)cell.accessoryView;
  GS_GLASS_CHECK([cell.textLabel.text isEqual:@"Google Photos · Liquid Glass"]&&[toggle isKindOfClass:UISwitch.class]&&!toggle.on&&toggle.enabled==modern);
  if(!modern){GS_GLASS_CHECK(!GSPhotosGlassEnabled());return YES;}

  // Load and attach the native controller before the first install/toggle. No
  // controller layout call is made after installation; GSSetPhotosGlass must find
  // this already-existing controller through the live UIWindow hierarchy.
  PHSTabBarController *controller=[PHSTabBarController new];GSFixtureAttach(controller,window);
  PHSSegmentedControl *segments=controller.floatingSegmentedControl;M3CButton *search=controller.floatingSearchButton;
  UIView *selection=segments.selection;UIImage *glyph=[search imageForState:UIControlStateNormal];UITapGestureRecognizer *gesture=controller.fixtureGesture;
  id savedNormal=[search backgroundColorForState:UIControlStateNormal];
  id savedHighlight=[search backgroundColorForState:UIControlStateHighlighted];
  id savedTint=[search tintColorForState:UIControlStateNormal];id savedShadow=[search shadowForState:UIControlStateNormal];
  NSUInteger initialNormalBrandCalls=search.normalBrandCalls;
  GS_GLASS_CHECK([savedNormal isEqual:GSFixturePhotosNormalColor()]&&[savedHighlight isEqual:GSFixturePhotosHighlightColor()]&&[savedTint isEqual:GSFixturePhotosTintColor()]&&[savedShadow isEqual:GSFixturePhotosShadow()]);
  GS_GLASS_CHECK(![savedNormal isEqual:GSFixtureBrandNormalColor()]&&![savedHighlight isEqual:GSFixtureBrandHighlightColor()]&&![savedTint isEqual:GSFixtureBrandTintColor()]&&![savedShadow isEqual:GSFixtureBrandShadow()]);
  GS_GLASS_CHECK(!GSPhotosGlassEnabled()&&!GSFixturePillEffect(segments)&&search.glassType==0&&search.opaque&&search.glassBrandCalls==0&&initialNormalBrandCalls==1);
  GS_GLASS_CHECK([search.allTargets containsObject:controller]&&[segments.allTargets containsObject:controller]&&[search.gestureRecognizers containsObject:gesture]);

  toggle.on=YES;[toggle sendActionsForControlEvents:UIControlEventValueChanged];
  GS_GLASS_CHECK(GSPhotosGlassEnabled());GSInstallPhotosGlass();GSInstallPhotosGlass();
  NSDictionary *snapshot=GSPhotosGlassSnapshot();
  GS_GLASS_CHECK([snapshot[@"available"]boolValue]&&[snapshot[@"hooksInstalled"]boolValue]&&[snapshot[@"attachedBars"]unsignedIntegerValue]>=1);

  UIVisualEffectView *pill=GSFixturePillEffect(segments);
  id capsule=((id(*)(id,SEL))objc_msgSend)(NSClassFromString(@"UICornerConfiguration"),NSSelectorFromString(@"capsuleConfiguration"));
  id configuredCorners=GSFixtureCornerConfiguration(pill);
  GS_GLASS_CHECK(pill&&[pill.effect isKindOfClass:NSClassFromString(@"UIGlassEffect")]&&!pill.userInteractionEnabled&&pill.accessibilityElementsHidden&&!pill.clipsToBounds);
  GS_GLASS_CHECK(CGRectEqualToRect(pill.frame,segments.bounds)&&configuredCorners&&[configuredCorners isEqual:capsule]);
  GS_GLASS_CHECK([segments.backgroundColor isEqual:UIColor.clearColor]&&!segments.opaque&&!segments.clipsToBounds);
  GS_GLASS_CHECK(segments.shadow.elevation==0&&!segments.shadow.adaptiveBackgroundColorEnabled&&[segments.shadow.backgroundColor isEqual:UIColor.clearColor]&&!segments.shadow.opaque);
  GS_GLASS_CHECK([segments.content.backgroundColor isEqual:UIColor.clearColor]&&!segments.content.opaque);
  GS_GLASS_CHECK(search.glassBrandCalls>0&&search.glassBrandNormalPasses==search.glassBrandCalls&&search.normalBrandCalls==initialNormalBrandCalls&&search.glassType==1&&[search isGlassEnabled]&&[search.glassEffectView isGlass]);
  GS_GLASS_CHECK([search.glassEffectView.effect isKindOfClass:NSClassFromString(@"UIGlassEffect")]&&search.glassEffectView.lastRequestedStyle==1&&[search.backgroundColor isEqual:UIColor.clearColor]&&!search.opaque&&search.layer.shadowOpacity==0);
  GS_GLASS_CHECK(search.glassEffectView.glass.backgroundOpacity>0&&search.glassEffectView.glass.backgroundOpacity<1&&CGColorGetAlpha(search.glassEffectView.glass.tintColor.CGColor)<1.0);
  GS_GLASS_CHECK(segments.selection==selection&&selection.superview==segments.content&&[search imageForState:UIControlStateNormal]==glyph&&[search.accessibilityLabel isEqual:@"Search"]);
  GS_GLASS_CHECK([search.allTargets containsObject:controller]&&[segments.allTargets containsObject:controller]&&[search.gestureRecognizers containsObject:gesture]);
  NSUInteger taps=controller.taps;segments.selectedSegmentIndex=2;[segments sendActionsForControlEvents:UIControlEventValueChanged];[search sendActionsForControlEvents:UIControlEventTouchUpInside];
  GS_GLASS_CHECK(controller.taps==taps+2&&segments.selectedSegmentIndex==2);

  // Calling the native normal-brand method while opted in must be redirected to
  // the native glass brand rather than silently reverting the search button.
  NSUInteger normalCalls=search.normalBrandCalls,glassCalls=search.glassBrandCalls;
  [search phs_brandIconTonalRound];
  GS_GLASS_CHECK(search.normalBrandCalls==normalCalls&&search.glassBrandCalls==glassCalls+1&&search.glassType==1&&!search.opaque&&search.glassEffectView.effect);
  GS_GLASS_CHECK(search.glassBrandNormalPasses==search.glassBrandCalls&&search.glassEffectView.lastRequestedStyle==1);

  // The alternate native material type is Regular glass (style 0). Verify the
  // fixture passes that exact style through UIKit while the owned effect is live,
  // then reapply the search brand to return to Clear/type 1.
  search.glassEffectView.glass.type=2;[search.glassEffectView updateGlassEffect];
  GS_GLASS_CHECK(search.glassEffectView.lastRequestedStyle==0&&[search.glassEffectView.effect isKindOfClass:NSClassFromString(@"UIGlassEffect")]);
  [search phs_brandIconTonalGlassRound];GS_GLASS_CHECK(search.glassType==1&&search.glassEffectView.lastRequestedStyle==1);

  // Native theme repainting may restore opaque segment colors. The layout/trait
  // hooks must immediately clear them again and remember the newest theme colors
  // so disabling the feature restores native appearance.
  NSUInteger themeUpdates=segments.themeUpdates;[segments traitCollectionDidChange:nil];
  GS_GLASS_CHECK(segments.themeUpdates==themeUpdates+1&&[segments.backgroundColor isEqual:UIColor.clearColor]&&[segments.shadow.backgroundColor isEqual:UIColor.clearColor]&&[segments.content.backgroundColor isEqual:UIColor.clearColor]);
  segments.frame=CGRectMake(0,0,320,64);[segments layoutSubviews];
  GS_GLASS_CHECK(CGRectEqualToRect(pill.frame,segments.bounds)&&segments.selection==selection);

  // Replacing the Material glass-effect view is a native lifecycle event. A
  // button layout must drop the stale pair, restore through the native normal
  // brand, bind the replacement, and invoke the native glass brand again.
  M3CMaterialGlassEffectView *oldEffect=search.glassEffectView;
  M3CMaterialGlassEffectView *replacement=[[M3CMaterialGlassEffectView alloc]initWithEffect:nil];replacement.glass=[M3CMaterialGlassEffect new];replacement.userInteractionEnabled=NO;
  [oldEffect removeFromSuperview];search.glassEffectView=replacement;[search insertSubview:replacement atIndex:0];
  glassCalls=search.glassBrandCalls;[search layoutSubviews];
  GS_GLASS_CHECK(search.glassEffectView==replacement&&replacement.superview==search&&search.glassBrandCalls>glassCalls&&search.glassType==1);
  GS_GLASS_CHECK([replacement.effect isKindOfClass:NSClassFromString(@"UIGlassEffect")]&&![oldEffect isDescendantOfView:search]);
  replacement.effect=nil;replacement.glass.type=0;glassCalls=search.glassBrandCalls;[search layoutSubviews];
  GS_GLASS_CHECK(search.glassBrandCalls==glassCalls+1&&search.glassType==1&&[replacement.effect isKindOfClass:NSClassFromString(@"UIGlassEffect")]);

  // Global hooks must not opt unrelated Material controls into glass.
  M3CButton *unrelated=[[M3CButton alloc]initWithFrame:CGRectMake(0,0,56,56)];unrelated.glassType=1;[unrelated.glassEffectView updateGlassEffect];
  GS_GLASS_CHECK(![unrelated isGlassEnabled]&&![unrelated.glassEffectView isGlass]&&!unrelated.glassEffectView.effect&&unrelated.opaque&&![unrelated.backgroundColor isEqual:UIColor.clearColor]);

  // A second already-loaded controller is discovered through the public setter,
  // proving pair state is independent across multiple Photos tab controllers.
  PHSTabBarController *second=[PHSTabBarController new];GSFixtureAttach(second,window);GSSetPhotosGlass(YES);
  GS_GLASS_CHECK(GSFixturePillEffect(second.floatingSegmentedControl)&&second.floatingSearchButton.glassType==1&&second.floatingSearchButton.glassEffectView.effect);
  GS_GLASS_CHECK([GSPhotosGlassSnapshot()[@"attachedBars"]unsignedIntegerValue]>=2);

  NSUInteger normalBeforeDisable=search.normalBrandCalls;
  GSSetPhotosGlass(NO);GSSetPhotosGlass(NO);
  GS_GLASS_CHECK(!GSPhotosGlassEnabled()&&!GSFixturePillEffect(segments)&&!GSFixturePillEffect(second.floatingSegmentedControl));
  GS_GLASS_CHECK([segments.backgroundColor isEqual:GSFixtureThemeSegmentColor()]&&segments.opaque&&segments.clipsToBounds);
  GS_GLASS_CHECK([segments.shadow.backgroundColor isEqual:GSFixtureThemeShadowColor()]&&segments.shadow.opaque&&segments.shadow.elevation==3&&segments.shadow.adaptiveBackgroundColorEnabled);
  GS_GLASS_CHECK([segments.content.backgroundColor isEqual:GSFixtureThemeContentColor()]&&segments.content.opaque);
  GS_GLASS_CHECK(search.glassType==0&&![search isGlassEnabled]&&![search.glassEffectView isGlass]&&!search.glassEffectView.effect&&search.opaque&&[search.backgroundColor isEqual:GSFixtureSearchColor()]);
  GS_GLASS_CHECK([[search backgroundColorForState:UIControlStateNormal] isEqual:savedNormal]&&[[search backgroundColorForState:UIControlStateHighlighted] isEqual:savedHighlight]);
  GS_GLASS_CHECK([[search tintColorForState:UIControlStateNormal] isEqual:savedTint]&&[[search shadowForState:UIControlStateNormal] isEqual:savedShadow]);
  GS_GLASS_CHECK(search.normalBrandCalls==normalBeforeDisable+1);
  GS_GLASS_CHECK(search.glassEffectView.glass.backgroundOpacity==1.0&&CGColorGetAlpha(search.glassEffectView.glass.tintColor.CGColor)==1.0);
  GS_GLASS_CHECK(second.floatingSearchButton.glassType==0&&second.floatingSearchButton.opaque&&!second.floatingSearchButton.glassEffectView.effect);
  GS_GLASS_CHECK(segments.selection==selection&&[search imageForState:UIControlStateNormal]==glyph&&[search.gestureRecognizers containsObject:gesture]);
  snapshot=GSPhotosGlassSnapshot();GS_GLASS_CHECK(![snapshot[@"enabled"]boolValue]&&[snapshot[@"attachedBars"]unsignedIntegerValue]==0);

  // Validate both bottom-bar targets before changing either. A valid segment pill
  // paired with a detached search material must leave both controls untouched.
  PHSTabBarController *badSearch=[PHSTabBarController new];[badSearch loadViewIfNeeded];
  PHSSegmentedControl *badSegments=badSearch.floatingSegmentedControl;M3CButton *badButton=badSearch.floatingSearchButton;
  UIColor *badSegmentColor=badSegments.backgroundColor,*badButtonColor=badButton.backgroundColor;
  [badButton.glassEffectView removeFromSuperview];
  GSSetPhotosGlass(YES);[badSearch viewDidLayoutSubviews];
  GS_GLASS_CHECK(!GSFixturePillEffect(badSegments)&&[badSegments.backgroundColor isEqual:badSegmentColor]&&badSegments.opaque&&badSegments.shadow.elevation==3);
  GS_GLASS_CHECK(badButton.glassBrandCalls==0&&badButton.glassType==0&&badButton.opaque&&[badButton.backgroundColor isEqual:badButtonColor]);
  GS_GLASS_CHECK([GSPhotosGlassSnapshot()[@"lastSkipReason"]isEqual:@"search_material_view_not_found"]);
  GSSetPhotosGlass(NO);

  // The reverse validation also holds: a valid search target must stay untouched
  // when the segment content contract is absent.
  PHSTabBarController *badSegmentsController=[PHSTabBarController new];[badSegmentsController loadViewIfNeeded];
  badSegmentsController.floatingSegmentedControl.content.accessibilityTraits=0;
  M3CButton *validSearch=badSegmentsController.floatingSearchButton;
  GSSetPhotosGlass(YES);[badSegmentsController viewDidLayoutSubviews];
  GS_GLASS_CHECK(!GSFixturePillEffect(badSegmentsController.floatingSegmentedControl)&&validSearch.glassBrandCalls==0&&validSearch.glassType==0&&validSearch.opaque);
  GS_GLASS_CHECK([GSPhotosGlassSnapshot()[@"lastSkipReason"]isEqual:@"segment_content_not_found"]);
  GSSetPhotosGlass(NO);

  GSFixtureDetach(second);GSFixtureDetach(controller);
  NSLog(@"PASS bottom glass native brand transitions, exact ABIs, gates, late discovery, target preservation, theme restore, replacement/recreation, multiple controllers and atomic hierarchy validation");
 } @finally {
  method_setImplementation(info,(IMP)GSOriginalBundleInfo);GSFixturePhotosVersion=nil;
 }
 GS_GLASS_CHECK(!GSPhotosGlassAvailable());
 return YES;
}
#undef GS_GLASS_CHECK
