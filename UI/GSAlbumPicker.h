#pragma once
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
@interface GSAlbumPicker : UITableViewController
@property(nonatomic,copy) void (^selection)(NSArray<NSString *> *identifiers);
@property(nonatomic,strong) PHCollectionList *folder;
@end
