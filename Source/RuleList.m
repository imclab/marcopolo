//
//  RuleList.m
//  MarcoPolo
//
//  Created by David Symonds on 23/07/08.
//

#import "RuleList.h"


@implementation RuleList

+ (id)ruleList
{
	return [[[self alloc] init] autorelease];
}

- (id)init
{
	if (!(self = [super init]))
		return nil;

	rules_ = [[NSMutableArray alloc] init];

	return self;
}

- (void)dealloc
{
	[rules_ release];
	[super dealloc];
}

- (NSEnumerator *)ruleEnumerator
{
	return [rules_ objectEnumerator];
}

- (void)addRule:(id<Rule>)rule
{
	[rules_ addObject:rule];
}

@end
