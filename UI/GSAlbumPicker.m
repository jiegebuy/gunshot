#import "GSAlbumPicker.h"
#import "../Shared/GSLocalization.h"
@interface GSAlbumPicker ()
@property(nonatomic,strong) NSArray<PHCollection *> *collections;
@property(nonatomic) BOOL loading;
@end
@implementation GSAlbumPicker
- (void)viewDidLoad{
 [super viewDidLoad];self.title=self.folder.localizedTitle?:GSL(@"Choose album");self.collections=@[];self.loading=YES;
 if(!self.folder)self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc]initWithTitle:GSL(@"Close") style:UIBarButtonItemStylePlain target:self action:@selector(close)];
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
  NSMutableArray *collections=[NSMutableArray array];
  if(self.folder){
   PHFetchResult *children=[PHCollection fetchCollectionsInCollectionList:self.folder options:nil];
   [children enumerateObjectsUsingBlock:^(PHCollection *c,NSUInteger i,BOOL *stop){[collections addObject:c];}];
  }else{
   PHFetchResult *smart=[PHAssetCollection fetchAssetCollectionsWithType:PHAssetCollectionTypeSmartAlbum subtype:PHAssetCollectionSubtypeAny options:nil];
   [smart enumerateObjectsUsingBlock:^(PHAssetCollection *c,NSUInteger i,BOOL *stop){
    if(c.assetCollectionSubtype!=PHAssetCollectionSubtypeSmartAlbumAllHidden)[collections addObject:c];
   }];
   PHFetchResult *top=[PHCollectionList fetchTopLevelUserCollectionsWithOptions:nil];
   [top enumerateObjectsUsingBlock:^(PHCollection *c,NSUInteger i,BOOL *stop){[collections addObject:c];}];
  }
  dispatch_async(dispatch_get_main_queue(),^{self.collections=collections;self.loading=NO;[self.tableView reloadData];});
 }});
}
- (void)close{[self dismissViewControllerAnimated:YES completion:nil];}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{return MAX(self.collections.count,1);}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path{
 UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"album"]?:[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"album"];
 cell.textLabel.numberOfLines=0;cell.accessoryType=UITableViewCellAccessoryNone;cell.detailTextLabel.text=nil;cell.imageView.image=nil;
 if(!self.collections.count){cell.textLabel.text=self.loading?GSL(@"Loading albums…"):GSL(@"No accessible albums");cell.selectionStyle=UITableViewCellSelectionStyleNone;return cell;}
 PHCollection *collection=self.collections[path.row];BOOL folder=[collection isKindOfClass:PHCollectionList.class];
 cell.textLabel.text=collection.localizedTitle?:GSL(@"Album");cell.selectionStyle=UITableViewCellSelectionStyleDefault;
 cell.imageView.image=[UIImage systemImageNamed:folder?@"folder":@"rectangle.stack"];
 cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
 cell.detailTextLabel.text=folder?GSL(@"Open folder"):GSL(@"Upload all accessible photos and videos");return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path{
 [tableView deselectRowAtIndexPath:path animated:YES];if(self.loading||path.row>=self.collections.count)return;
 PHCollection *collection=self.collections[path.row];
 if([collection isKindOfClass:PHCollectionList.class]){
  GSAlbumPicker *child=[[GSAlbumPicker alloc]initWithStyle:UITableViewStyleInsetGrouped];child.folder=(PHCollectionList *)collection;child.selection=self.selection;
  [self.navigationController pushViewController:child animated:YES];return;
 }
 if(![collection isKindOfClass:PHAssetCollection.class])return;
 self.loading=YES;
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
  PHFetchOptions *options=[PHFetchOptions new];options.includeHiddenAssets=NO;
  PHFetchResult *assets=[PHAsset fetchAssetsInAssetCollection:(PHAssetCollection *)collection options:options];
  NSMutableArray<NSString *> *identifiers=[NSMutableArray arrayWithCapacity:assets.count];
  [assets enumerateObjectsUsingBlock:^(PHAsset *asset,NSUInteger i,BOOL *stop){if(asset.localIdentifier.length)[identifiers addObject:asset.localIdentifier];}];
  NSArray<NSString *> *selectionIDs=[identifiers copy];
  dispatch_async(dispatch_get_main_queue(),^{
   self.loading=NO;
   UIAlertController *confirm=[UIAlertController alertControllerWithTitle:collection.localizedTitle?:GSL(@"Album") message:selectionIDs.count?[NSString stringWithFormat:GSL(@"Add %lu items to the queue? Originals are prepared one at a time. Keep the app open."),(unsigned long)selectionIDs.count]:GSL(@"No accessible photos in this album. Check photo permissions.") preferredStyle:UIAlertControllerStyleAlert];
   [confirm addAction:[UIAlertAction actionWithTitle:GSL(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
   if(selectionIDs.count)[confirm addAction:[UIAlertAction actionWithTitle:GSL(@"Add") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
    void(^selection)(NSArray<NSString *> *)=self.selection;
    [self dismissViewControllerAnimated:YES completion:^{if(selection)selection(selectionIDs);}];
   }]];
   [self presentViewController:confirm animated:YES completion:nil];
  });
 }});
}
@end
