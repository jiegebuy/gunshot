#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

// GSPhotosGlass uses a real UITabBarController so UIKit owns the iOS 26+
// floating platter, selected lens and press interaction. Google Photos 7.92
// builds differ in whether setSelectedSegmentIndex: also emits ValueChanged, so
// bridge the controller delegate without assuming either behavior.
@interface GSPhotosGlassValueChangeProbe : NSObject
@property(nonatomic) BOOL fired;
- (void)valueChanged:(id)sender;
@end

@implementation GSPhotosGlassValueChangeProbe
- (void)valueChanged:(id)sender{self.fired=YES;}
@end

static IMP GSPhotosGlassOriginalTabControllerDidSelect;
static IMP GSPhotosGlassOriginalControllerLayout;

static BOOL GSPhotosGlassOwnsTabController(id controller){
 if(![controller isKindOfClass:UITabBarController.class])return NO;
 id delegate=((UITabBarController *)controller).delegate;
 return delegate&&[NSStringFromClass(object_getClass(delegate)) isEqualToString:@"GSPhotosGlassPair"];
}

static void GSPhotosGlassControllerLayout(UITabBarController *controller,SEL selector){
 if(GSPhotosGlassOriginalControllerLayout)
  ((void(*)(id,SEL))GSPhotosGlassOriginalControllerLayout)(controller,selector);
 if(!GSPhotosGlassOwnsTabController(controller)||!controller.isViewLoaded)return;
 // UITabBarController may restore its normal compact tab-bar frame whenever it
 // switches child controllers or updates traits. Keep this specific Gunshot
 // controller's system-owned bar pinned to the Photos floating viewport after
 // every UIKit layout pass; its private platter/lens hierarchy remains untouched.
 controller.tabBar.frame=controller.view.bounds;
 [controller.tabBar setNeedsLayout];[controller.tabBar layoutIfNeeded];
}

static void GSPhotosGlassTabControllerDidSelect(id pair,SEL selector,UITabBarController *tabController,UIViewController *viewController){
 SEL segmentsSelector=NSSelectorFromString(@"segments");
 id segments=[pair respondsToSelector:segmentsSelector]?((id(*)(id,SEL))objc_msgSend)(pair,segmentsSelector):nil;
 BOOL canObserve=[segments isKindOfClass:UIControl.class]&&[segments respondsToSelector:NSSelectorFromString(@"selectedSegmentIndex")];
 NSInteger before=NSNotFound;
 GSPhotosGlassValueChangeProbe *probe=nil;
 if(canObserve){
  before=((NSInteger(*)(id,SEL))objc_msgSend)(segments,NSSelectorFromString(@"selectedSegmentIndex"));
  probe=[GSPhotosGlassValueChangeProbe new];
  [(UIControl *)segments addTarget:probe action:@selector(valueChanged:) forControlEvents:UIControlEventValueChanged];
 }

 ((void(*)(id,SEL,UITabBarController *,UIViewController *))GSPhotosGlassOriginalTabControllerDidSelect)(pair,selector,tabController,viewController);

 if(!probe)return;
 [(UIControl *)segments removeTarget:probe action:@selector(valueChanged:) forControlEvents:UIControlEventValueChanged];
 NSInteger after=((NSInteger(*)(id,SEL))objc_msgSend)(segments,NSSelectorFromString(@"selectedSegmentIndex"));
 if(before!=after&&after==(NSInteger)tabController.selectedIndex&&!probe.fired)
  [(UIControl *)segments sendActionsForControlEvents:UIControlEventValueChanged];
}

__attribute__((constructor)) static void GSInstallPhotosGlassTabEventBridge(void){
 Class pairClass=NSClassFromString(@"GSPhotosGlassPair");
 SEL selectSelector=@selector(tabBarController:didSelectViewController:);
 Method selectMethod=pairClass?class_getInstanceMethod(pairClass,selectSelector):NULL;
 if(selectMethod){
  GSPhotosGlassOriginalTabControllerDidSelect=method_getImplementation(selectMethod);
  method_setImplementation(selectMethod,(IMP)GSPhotosGlassTabControllerDidSelect);
 }

 // Do not call method_setImplementation on the Method returned by
 // class_getInstanceMethod(UITabBarController,...). On iOS 27 that selector is
 // inherited from UIViewController, so mutating that Method replaces
 // UIViewController's implementation globally and our wrapper receives ordinary
 // UIViewController instances (then `delegate` crashes with an unrecognized
 // selector). class_replaceMethod installs/replaces the method on
 // UITabBarController itself while preserving the inherited/current IMP as the
 // implementation we chain to.
 SEL layoutSelector=@selector(viewDidLayoutSubviews);
 Method layoutMethod=class_getInstanceMethod(UITabBarController.class,layoutSelector);
 if(layoutMethod){
  IMP inheritedOrCurrent=method_getImplementation(layoutMethod);
  const char *types=method_getTypeEncoding(layoutMethod);
  IMP replaced=class_replaceMethod(UITabBarController.class,layoutSelector,(IMP)GSPhotosGlassControllerLayout,types);
  GSPhotosGlassOriginalControllerLayout=replaced?:inheritedOrCurrent;
 }
}
