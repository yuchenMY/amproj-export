// 猫鹤 AM · 实际策略校验和工程备份收集边界回归。
#import <Foundation/Foundation.h>
#import "AMClientReleasePolicy.h"
#import "AMProjZIPWriter.h"
#import "AMProjImportArchive.h"
#include <assert.h>
#include <stdio.h>
// AMPROJ_PRODUCTION_BACKUP_COLLECTOR
int main(void) {
 @autoreleasepool {
  NSMutableDictionary *p=[@{@"protocol":@1,@"channel":@"stable",@"revision":@1,@"serverNow":@1000,@"forceAfter":@2000,
   @"minimumRelease":@175,@"latestRelease":@180,@"enabled":@YES,@"retired":@NO,@"message":@"更新说明",@"downloadURL":@"https://example.test/update"} mutableCopy];
  assert(AMClientReleaseValidatedPolicy(p,@"stable"));assert(!AMClientReleaseValidatedPolicy(p,@"beta"));
  assert(!AMClientReleasePolicyBlocked(p,174,1999));assert(AMClientReleasePolicyBlocked(p,174,2000));assert(!AMClientReleasePolicyBlocked(p,175,2000));
  p[@"blocked"]=@YES;assert(!AMClientReleasePolicyBlocked(p,999,3000));
  for(id bad in @[@"https://user:pass@example.test",@"http://example.test",@"javascript:alert(1)",NSNull.null]) {
   p[@"downloadURL"]=bad;assert(!AMClientReleaseValidatedPolicy(p,@"stable"));
  }
  p[@"downloadURL"]=@"https://example.test/update";p[@"minimumRelease"]=@181;assert(!AMClientReleaseValidatedPolicy(p,@"stable"));p[@"minimumRelease"]=@175;
  p[@"retired"]=@YES;assert(!AMClientReleaseValidatedPolicy(p,@"stable"));p[@"channel"]=@"beta";
  assert(AMClientReleaseValidatedPolicy(p,@"beta") && AMClientReleasePolicyBlocked(p,9999,3000));
  p[@"enabled"]=@NO;assert(!AMClientReleasePolicyBlocked(p,1,3000));
  assert(AMClientReleaseSafePresenter(@"AlightMotion.HomeVC"));
  assert(AMClientReleaseSafePresenter(@"AMHomeUIController"));
  assert(!AMClientReleaseSafePresenter(@"AMProjShareVideoReplicaVC"));
  assert(!AMClientReleaseSafePresenter(@"AlightMotion.EditorVC"));
  NSURL *root=[[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
  NSFileManager *fm=NSFileManager.defaultManager;assert([fm createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil]);
  NSURL *cache=[root URLByAppendingPathComponent:@"cache/policy.plist"];
  p[@"enabled"]=@YES;
  assert(AMClientReleaseSaveCache(cache,p,1234.56789));
  NSTimeInterval received=0;
  NSDictionary *loaded=AMClientReleaseLoadCache(cache,@"beta",&received);
  assert(loaded && fabs(received-1234.56789)<0.0001);
  assert(AMClientReleasePolicyBlocked(loaded,174,[loaded[@"serverNow"] doubleValue]+(3234.56789-received)));
  assert(!AMClientReleaseLoadCache(cache,@"stable",NULL));
  NSURL *deps=[root URLByAppendingPathComponent:@"project-dependencies" isDirectory:YES];assert([fm createDirectoryAtURL:deps withIntermediateDirectories:NO attributes:nil error:nil]);
  NSString *scene=[NSUUID.UUID.UUIDString stringByAppendingString:@".xml"];
  NSString *scene2=[NSUUID.UUID.UUIDString stringByAppendingString:@".xml"];
  assert([@"<scene title=\"工程一\" type=\"project\"><media uri=\"am-internal:///media.png\"/></scene>" writeToURL:[root URLByAppendingPathComponent:scene] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
  assert([@"<scene title=\"工程二\" type=\"project\"><media uri=\"amproj:second.png\"/></scene>" writeToURL:[root URLByAppendingPathComponent:scene2] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
  assert([@"secret" writeToURL:[root URLByAppendingPathComponent:@"amproj-account-token"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
  assert([@"not a scene" writeToURL:[root URLByAppendingPathComponent:@"other.xml"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
  assert([@"image bytes" writeToURL:[deps URLByAppendingPathComponent:@"media.png"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
  assert([@"second image" writeToURL:[deps URLByAppendingPathComponent:@"second.png"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
  NSMutableDictionary *scenes=nil,*resources=nil;NSError *error=nil;
  assert(AMReleaseCollectBackup(root,&scenes,&resources,&error));assert(scenes.count==2 && resources.count==2 && scenes[scene] && resources[@"media.png"]);
  NSURL *outputs=[root URLByAppendingPathComponent:@"out" isDirectory:YES];
  assert([fm createDirectoryAtURL:outputs withIntermediateDirectories:NO attributes:nil error:nil]);
  NSArray *packages=AMReleaseWriteBackup(outputs,scenes,resources,&error);assert(packages.count==2);
  NSMutableSet *restored=[NSMutableSet set];
  for(NSURL *package in packages) {
   NSURL *xml=nil;NSDictionary *metrics=nil;
   assert(AMProjPrepareNativeImport(package,outputs,&xml,&metrics,&error));
   assert([metrics[@"xml_count"] integerValue]==1 && [metrics[@"resource_count"] integerValue]==1);
   assert([metrics[@"manifest_verified"] boolValue] && [metrics[@"missing_reference_count"] integerValue]==0 && [metrics[@"missing_media_signature_count"] integerValue]==0);
   NSString *text=[NSString stringWithContentsOfURL:xml encoding:NSUTF8StringEncoding error:nil];
   if([text containsString:@"工程一"]) [restored addObject:@"one"];
   if([text containsString:@"工程二"]) [restored addObject:@"two"];
   NSURL *extracted=[NSURL fileURLWithPath:metrics[@"extraction_directory"] isDirectory:YES];
   NSString *resource=[text containsString:@"工程一"] ? @"media.png" : @"second.png";
   assert([[NSData dataWithContentsOfURL:[extracted URLByAppendingPathComponent:resource]] isEqualToData:[NSData dataWithContentsOfURL:resources[resource]]]);
  }
  assert(restored.count==2);
  assert(!AMReleaseWriteBackup(outputs,scenes,@{},&error));
  NSURL *link=[deps URLByAppendingPathComponent:@"secret-link"];
  assert([fm createSymbolicLinkAtURL:link withDestinationURL:[root URLByAppendingPathComponent:@"amproj-account-token"] error:nil]);
  assert(!AMReleaseCollectBackup(root,&scenes,&resources,&error));assert([fm removeItemAtURL:link error:nil]);
  assert([fm removeItemAtURL:[root URLByAppendingPathComponent:scene] error:nil]);
  assert([fm removeItemAtURL:[root URLByAppendingPathComponent:scene2] error:nil]);
  assert(!AMReleaseCollectBackup(root,&scenes,&resources,&error) && error.code==1);
  assert([fm removeItemAtURL:root error:nil]);
  puts("CLIENT_RELEASE_POLICY_AND_BACKUP_PASS");
 }
}
