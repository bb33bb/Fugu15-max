#import "trustcache.h"

#import <libjailbreak/pplrw.h>
#import <libjailbreak/kcall.h>
#import <sys/stat.h>
#import <unistd.h>
#import <libjailbreak/boot_info.h>
#import "trustcache_structs.h"
#import "JBDTCPage.h"
#import "spawn_wrapper.h"

NSString* normalizePath(NSString* path)
{
	return [[path stringByResolvingSymlinksInPath] stringByStandardizingPath];
}

JBDTCPage *trustCacheMapInFreePage(void)
{
	// Find page that has slots left
	for (JBDTCPage *page in gTCPages) {
		[page mapIn];
		if (page.amountOfSlotsLeft > 0) {
			return page;
		}
		[page mapOut];
	}

	// No page found, allocate new one
	JBDTCPage *newPage = [[JBDTCPage alloc] initAllocateAndLink];
	[newPage mapIn];
	return newPage;
}

void trustCacheAddEntry(trustcache_entry entry)
{
	JBDTCPage *freePage = trustCacheMapInFreePage();
	[freePage addEntry:entry];
	[freePage sort];
	[freePage mapOut];
}

void trustCacheRemoveEntry(trustcache_entry entry)
{
	for (JBDTCPage *page in gTCPages) {
		BOOL removed = [page removeEntry:entry];
		if (removed) return;
	}
}

void fileEnumerateTrustCacheEntries(const char *filePath, void (^enumerateBlock)(trustcache_entry entry)) {
	struct cdhashes cdh = { 0 };
	struct stat sb;
	stat(filePath, &sb);
	find_cdhash(filePath, &sb, &cdh);

	for (int i = 0; i < cdh.count; i++) {
		trustcache_entry entry;
		memcpy(&entry.hash, &cdh.h[i].cdhash[0], CS_CDHASH_LEN);
		entry.hash_type = 0x2;
		entry.flags = 0x0;
		enumerateBlock(entry);
	}

	if (cdh.h) {
		free(cdh.h);
	}
}

void trustCacheUploadFile(const char *filePath)
{
	fileEnumerateTrustCacheEntries(filePath, ^(trustcache_entry entry) {
		trustCacheAddEntry(entry);
	});
}

void trustCacheUploadCDHashFromData(NSData *cdHash)
{
	if (cdHash.length != CS_CDHASH_LEN) return;

	trustcache_entry entry;
	memcpy(&entry.hash, cdHash.bytes, CS_CDHASH_LEN);
	entry.hash_type = 0x2;
	entry.flags = 0x0;
	trustCacheAddEntry(entry);
}

void trustCacheUploadCDHashesFromArray(NSArray *cdHashArray)
{
	__block JBDTCPage *mappedInPage = nil;
	for (NSData *cdHash in cdHashArray) {
		if (!mappedInPage || mappedInPage.amountOfSlotsLeft == 0) {
			// If there is still a page mapped, map it out now
			if (mappedInPage) {
				[mappedInPage sort];
				[mappedInPage mapOut];
			}

			mappedInPage = trustCacheMapInFreePage();
		}

		trustcache_entry entry;
		memcpy(&entry.hash, cdHash.bytes, CS_CDHASH_LEN);
		entry.hash_type = 0x2;
		entry.flags = 0x0;
		[mappedInPage addEntry:entry];
	}

	if (mappedInPage) {
		[mappedInPage sort];
		[mappedInPage mapOut];
	}
}

void trustCacheUploadDirectory(NSString *directoryPath)
{
	NSString *resolvedPath = [[directoryPath stringByResolvingSymlinksInPath] stringByStandardizingPath];
	NSDirectoryEnumerator<NSURL *> *directoryEnumerator = [[NSFileManager defaultManager] enumeratorAtURL:[NSURL fileURLWithPath:resolvedPath isDirectory:YES] 
																			   includingPropertiesForKeys:@[NSURLIsSymbolicLinkKey]
																								  options:0
																							 errorHandler:nil];
	__block JBDTCPage *mappedInPage = nil;
	for (NSURL *enumURL in directoryEnumerator) {
		NSNumber *isSymlink;
		[enumURL getResourceValue:&isSymlink forKey:NSURLIsSymbolicLinkKey error:nil];
		if (isSymlink && ![isSymlink boolValue]) {
			fileEnumerateTrustCacheEntries(enumURL.fileSystemRepresentation, ^(trustcache_entry entry) {
				if (!mappedInPage || mappedInPage.amountOfSlotsLeft == 0) {
					// If there is still a page mapped, map it out now
					if (mappedInPage) {
						[mappedInPage sort];
						[mappedInPage mapOut];
					}

					mappedInPage = trustCacheMapInFreePage();
				}

				NSLog(@"[TC %@] Adding entry for %@ (Initial Run)", directoryPath, enumURL.path);
				[mappedInPage addEntry:entry];
			});
		}
	}

	if (mappedInPage) {
		[mappedInPage sort];
		[mappedInPage mapOut];
	}
}

void rebuildTrustCache(void)
{
	// nuke existing
	for (JBDTCPage *page in [gTCPages reverseObjectEnumerator]) {
		[page unlinkAndFree];
	}

	NSLog(@"Triggering initial trustcache upload...");
	trustCacheUploadDirectory(@"/var/jb");
	NSLog(@"Initial TrustCache upload done!");
}