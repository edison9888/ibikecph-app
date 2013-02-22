 //
//  SMRoute.m
//  I Bike CPH
//
//  Created by Petra Markovic on 1/28/13.
//  Copyright (c) 2013 Spoiled Milk. All rights reserved.
//

#import "SMLocationManager.h"
#import "SMRoute.h"
#import "SMUtil.h"

#import "SBJson.h"

#define MAX_DISTANCE_FROM_PATH 20 // in meters

@interface SMRoute()
@property (nonatomic, strong) SMRequestOSRM * request;
@property (nonatomic, strong) CLLocation * lastRecalcLocation;
@end

@implementation SMRoute {


}

- (id)init {
    self = [super init];
    if (self) {
        self.tripDistance = -1;
        self.caloriesBurned = -1;
        self.averageSpeed = -1;
        approachingTurn = NO;
        lastVisitedWaypointIndex = -1;
        self.recalculationInProgress = NO;
        self.lastRecalcLocation = [[CLLocation alloc] initWithLatitude:0 longitude:0];
    }
    return self;
}

- (id)initWithRouteStart:(CLLocationCoordinate2D)start andEnd:(CLLocationCoordinate2D)end andDelegate:(id<SMRouteDelegate>)dlg {
    self = [self init];
    if (self) {
        [self setLocationStart:start];
        [self setLocationEnd:end];
        [self setDelegate:dlg];
        SMRequestOSRM * r = [[SMRequestOSRM alloc] initWithDelegate:self];
        [self setRequest:r];
        [r setAuxParam:@"startRoute"];
        [r getRouteFrom:start to:end via:nil];
    }
    return self;
}

- (BOOL) isTooFarFromRouteSegment:(CLLocation *)loc from:(SMTurnInstruction *)turnA to:(SMTurnInstruction *)turnB maxDistance:(double)maxDistance {
    double min = 100000.0;

    for (int i = lastVisitedWaypointIndex; i < turnB.waypointsIndex; i++) {
        CLLocation *a = [self.waypoints objectAtIndex:i];
        CLLocation *b = [self.waypoints objectAtIndex:(i + 1)];
        double d = distanceFromLineInMeters(loc.coordinate, a.coordinate, b.coordinate);
        if (d < 0.0)
            continue;

//      if (d <= maxDistance)
//          return FALSE;
        if (d <= min) {
            min = d;
            lastVisitedWaypointIndex = i;
        }

        if (min < 2) {
            // Close enough :)
            break;
        }
    }
//    return TRUE;
//    debugLog(@"lastVisitedWaypointIndex = %d. Distance from route segment: %g", lastVisitedWaypointIndex, min);
    return min > maxDistance;
}

- (BOOL) isTooFarFromRoute:(CLLocation *)loc maxDistance:(int)maxDistance {
//    debugLog(@"\nisTooFarFromRoute()");
    SMTurnInstruction *lastTurn = [self.pastTurnInstructions lastObject];
    if (self.turnInstructions.count > 0) {

        SMTurnInstruction *prevTurn = lastTurn;
        SMTurnInstruction *nextTurn;
        for (int i = 0; i < self.turnInstructions.count; i++, prevTurn = nextTurn) {
            nextTurn = [self.turnInstructions objectAtIndex:i];

            /**
             * Check if we are (significantly) moving away from the start.
             * If you start routing but never pass through the first instruction location
             * the routing will always return false.
             * It will now check against the first route point and recalculate if neccessary
             */
            if (i == 0 && !lastTurn) {
                if (self.visitedLocations && self.visitedLocations.count > 0) {
                    double initialDistanceFromStart = [loc distanceFromLocation:nextTurn.loc];
                    double currentDistanceFromStart = [loc distanceFromLocation:nextTurn.loc];
                    debugLog(@"Initial distance from start: %g", initialDistanceFromStart);
                    debugLog(@"Current distance from start: %g", currentDistanceFromStart);
                    return currentDistanceFromStart > initialDistanceFromStart + maxDistance;
                }
                return FALSE;
            }

//            double d = [self distanceFromRouteSegment:loc from:prevTurn to:nextTurn];
//            if (d <= maxDistance) {// && (loc.course < 0.0 || fabs(loc.course - lastTurn.azimuth) <= 20.0)) {
            if (![self isTooFarFromRouteSegment:loc from:prevTurn to:nextTurn maxDistance:maxDistance]) {
//                debugLog(@"distance from path: %g ok", d);
                if (i > 0)
                    debugLog(@"correcting segment to %@", nextTurn.wayName);
                for (int k = 0; k < i; k++)
                    [self updateSegment];
                if (approachingTurn)
                    approachingTurn = approachingTurn || i > 0;
                return NO;
            } else {
//                debugLog(@"distance from path: %g too far (limit is %d)", d, maxDistance);
            }
        }
        return YES;
    }
    return NO;
}

- (void) recalculateRoute:(CLLocation *)loc {
    @synchronized(self) {
        if (self.recalculationInProgress) {
            return;
        }
        
        CGFloat distance = [loc distanceFromLocation:self.lastRecalcLocation];
        if (distance < MIN_DISTANCE_FOR_RECALCULATION) {
            return;
        }
        NSLog(@"Distance: %f", distance);
        self.lastRecalcLocation = loc;
            
        self.recalculationInProgress = YES;
        NSLog(@"Recalculating route!");
        
        
        if (self.delegate && [self.delegate respondsToSelector:@selector(routeRecalculationStarted)]) {
            [self.delegate routeRecalculationStarted];
        }
        
        CLLocation *end = [self getEndLocation];
        if (!loc || !end)
            return;
        
        
        SMRequestOSRM  * r = [[SMRequestOSRM alloc] initWithDelegate:self];
        [self setRequest:r];
        [r setAuxParam:@"routeRecalc"];

        // Uncomment code below if previous part of the route needs to be displayed.
//        NSMutableArray *viaPoints = [NSMutableArray array];
//        for (SMTurnInstruction *turn in self.pastTurnInstructions)
//            [viaPoints addObject:turn.loc];
//        [viaPoints addObject:loc];
//        [r getRouteFrom:((CLLocation *)[self.waypoints objectAtIndex:0]).coordinate to:end.coordinate via:viaPoints];

        [r getRouteFrom:loc.coordinate to:end.coordinate via:nil checksum:self.routeChecksum destinationHint:self.destinationHint];
    }
}

//double course(CLLocation *loc1, CLLocation *loc2) {
//    return 0.0;
//}

- (void) updateSegment {
    debugLog(@"Update segment!!!!");
    if (!self.delegate) {
        NSLog(@"Warning: delegate not set while in updateSegment()!");
        return;
    }

    if (self.turnInstructions.count > 0) {
        @synchronized(self.turnInstructions) {
            [self.pastTurnInstructions addObject:[self.turnInstructions objectAtIndex:0]];
            [self.turnInstructions removeObjectAtIndex:0];
            [self.delegate updateTurn:YES];
        }
        

        if (self.turnInstructions.count == 0)
            [self.delegate reachedDestination];
    }
}

- (BOOL) approachingFinish {
    return approachingTurn && self.turnInstructions.count == 1;
}

- (void) visitLocation:(CLLocation *)loc {
    
    if (self.turnInstructions.count <= 0)
        return;

    [self updateDistanceToNextTurn:loc];

    if (self.tripDistance < 0)
        self.tripDistance = 0;
    if (self.visitedLocations.count > 0)
        self.tripDistance += [loc distanceFromLocation:[[self.visitedLocations lastObject] objectForKey:@"location"]];
    
    @synchronized(self.visitedLocations) {
        if (!self.visitedLocations)
            self.visitedLocations = [NSMutableArray array];
        [self.visitedLocations addObject:@{
         @"location" : loc,
         @"date" : [NSDate date]
         }];
    }

    
    @synchronized(self) {
        if (self.recalculationInProgress) {
            return;
        }
    }

    
    // Check if we are finishing:
    if (self.turnInstructions.count == 1) {
        double distanceToFinish = [loc distanceFromLocation:[self getEndLocation]];
        double speed = loc.speed > 0 ? loc.speed : 5;
        int timeToFinish = 100;
        if (speed > 0) {
            timeToFinish = distanceToFinish / speed;
            debugLog(@"finishing in %d", timeToFinish);
        }
        if (distanceToFinish < 10.0 || timeToFinish <= 3) {
            approachingTurn = NO;
            [self updateSegment];
            return;
        }
    }

    // are we approaching some turn or are we past some turn
    if (approachingTurn) {
        SMTurnInstruction *nextTurn = [self.turnInstructions objectAtIndex:0];
        
        double d = [loc distanceFromLocation:[nextTurn getLocation]];
        if (self.turnInstructions.count > 0 && d > 20.0) {
            if (loc.course >= 0.0)
                debugLog(@"loc.course: %f turn->azimuth: %f", loc.course, nextTurn.azimuth);

            approachingTurn = NO;

//            if (loc.course >= 0.0 && fabs(loc.course - nextTurn.azimuth) > 20.0) {
//                debugLog(@"Missed turn!");
//            } else {
                debugLog(@"Past turn: %@", nextTurn.wayName);
                [self updateSegment];
//            }
        }
    } else if (!approachingTurn) {
        for (int i = 0; i < self.turnInstructions.count; i++) {
            SMTurnInstruction *nextTurn = [self.turnInstructions objectAtIndex:i];
            double distanceFromTurn = [loc distanceFromLocation:[nextTurn getLocation]];
            if ((distanceFromTurn < 10.0 || (i == self.turnInstructions.count - 1 && distanceFromTurn < 20.0))) {
//                && (loc.course < 0.0 || fabs(loc.course - nextTurn.azimuth) <= 20.0)) {
                approachingTurn = YES;
                if (i > 0)
                    [self updateSegment];
                debugLog(@"Approaching turn %@ in %.1g m", nextTurn.wayName, distanceFromTurn);
                break;
            }
        }
    }

    // Check if we went too far from the calculated route and, if so, recalculate route
    // max allowed distance depends on location's accuracy
    int maxD = loc.horizontalAccuracy >= 0 ? (loc.horizontalAccuracy / 3 + 20) : MAX_DISTANCE_FROM_PATH;
    if (![self approachingFinish] && self.delegate && [self isTooFarFromRoute:loc maxDistance:maxD]) {
        approachingTurn = NO;
        [self recalculateRoute:loc];
    }
}

- (CLLocation *) getStartLocation {
    if (self.waypoints && self.waypoints.count > 0)
        return [self.waypoints objectAtIndex:0];
    return NULL;
}

- (CLLocation *) getEndLocation {
    if (self.waypoints && self.waypoints.count > 0)
        return [self.waypoints lastObject];
    return NULL;
}

- (CLLocation *) getFirstVisitedLocation {
    if (self.visitedLocations && self.visitedLocations.count > 0)
        return [[self.visitedLocations objectAtIndex:0] objectForKey:@"location"];
    return NULL;
}

- (CLLocation *) getLastVisitedLocation {
    if (self.visitedLocations && self.visitedLocations.count > 0)
        return [[self.visitedLocations lastObject] objectForKey:@"location"];
    return NULL;
}

/*
 * Decoder for the Encoded Polyline Algorithm Format
 * https://developers.google.com/maps/documentation/utilities/polylinealgorithm
 */
NSMutableArray* decodePolyline (NSString *encodedString) {

    const char *bytes = [encodedString UTF8String];
    size_t len = strlen(bytes);

    int lat = 0, lng = 0;

    NSMutableArray *locations = [NSMutableArray array];
    for (int i = 0; i < len;) {
        for (int k = 0; k < 2; k++) {

            uint32_t delta = 0;
            int shift = 0;

            unsigned char c;
            do {
                c = bytes[i++] - 63;
                delta |= (c & 0x1f) << shift;
                shift += 5;
            } while (c & 0x20);

            delta = (delta & 0x1) ? ((~delta >> 1) | 0x80000000) : (delta >> 1);
            (k == 0) ? (lat += delta) : (lng += delta);
        }
//      debugLog(@"decodePolyline(): (%d, %d)", lat, lng);

        [locations addObject:[[CLLocation alloc] initWithLatitude:((double)lat / 1e5) longitude:((double)lng / 1e5)]];
    }

    return locations;
}

- (BOOL) parseFromJson:(NSDictionary *)jsonRoot delegate:(id<SMRouteDelegate>) dlg {
    

//    SMRoute *route = [[SMRoute alloc] init];
    @synchronized(self.waypoints) {
        self.waypoints = decodePolyline([jsonRoot objectForKey:@"route_geometry"]);
    }

    if (self.waypoints.count < 2)
        return NO;

    @synchronized(self.turnInstructions) {
        self.turnInstructions = [NSMutableArray array];
    }
    self.estimatedTimeForRoute = [[[jsonRoot objectForKey:@"route_summary"] objectForKey:@"total_time"] integerValue];
    self.estimatedRouteDistance = [[[jsonRoot objectForKey:@"route_summary"] objectForKey:@"total_distance"] integerValue];
    self.routeChecksum = nil;
    self.destinationHint = nil;
    
    if ([jsonRoot objectForKey:@"hint_data"] && [[jsonRoot objectForKey:@"hint_data"] objectForKey:@"checksum"]) {
        self.routeChecksum = [NSString stringWithFormat:@"%@", [[jsonRoot objectForKey:@"hint_data"] objectForKey:@"checksum"]];
    }
    
    if ([jsonRoot objectForKey:@"hint_data"] && [[jsonRoot objectForKey:@"hint_data"] objectForKey:@"locations"] && [[[jsonRoot objectForKey:@"hint_data"] objectForKey:@"locations"] isKindOfClass:[NSArray class]]) {
        self.destinationHint = [NSString stringWithFormat:@"%@", [[[jsonRoot objectForKey:@"hint_data"] objectForKey:@"locations"] lastObject]];
    }
    
    NSArray *routeInstructions = [jsonRoot objectForKey:@"route_instructions"];
    if (routeInstructions && routeInstructions.count > 0) {
        int prevlengthInMeters = 0;
        NSString *prevlengthWithUnit = @"";
        for (id jsonObject in routeInstructions) {
            SMTurnInstruction *instruction = [[SMTurnInstruction alloc] init];

            NSArray * arr = [[NSString stringWithFormat:@"%@", [jsonObject objectAtIndex:0]] componentsSeparatedByString:@"-"];
            int pos = [(NSString*)[arr objectAtIndex:0] intValue];
            
            if (pos <= 17) {
                instruction.drivingDirection = pos;
                if ([arr count] > 1 && [arr objectAtIndex:1]) {
                    instruction.ordinalDirection = [arr objectAtIndex:1];
                } else {
                    instruction.ordinalDirection = @"";
                }
                instruction.wayName = (NSString *)[jsonObject objectAtIndex:1];
                instruction.lengthInMeters = prevlengthInMeters;
                prevlengthInMeters = [(NSNumber *)[jsonObject objectAtIndex:2] intValue];
                instruction.timeInSeconds = [(NSNumber *)[jsonObject objectAtIndex:4] intValue];
                instruction.lengthWithUnit = prevlengthWithUnit;
                /**
                 * Save length to next turn with units so we don't have to generate it each time
                 * It's formatted just the way we like it
                 */
                instruction.fixedLengthWithUnit = formatDistance(prevlengthInMeters);
                prevlengthWithUnit = (NSString *)[jsonObject objectAtIndex:5];
                instruction.directionAbrevation = (NSString *)[jsonObject objectAtIndex:6];
                instruction.azimuth = [(NSNumber *)[jsonObject objectAtIndex:7] floatValue];
                
                int position = [(NSNumber *)[jsonObject objectAtIndex:3] intValue];
                instruction.waypointsIndex = position;
                //          instruction->waypoints = route;
                
                if (self.waypoints && position >= 0 && position < self.waypoints.count)
                    instruction.loc = [self.waypoints objectAtIndex:position];
                
                @synchronized(self.turnInstructions) {
                    [self.turnInstructions addObject:instruction];
                }
            }

//          [route.turnInstructions addObject:[SMTurnInstruction parseInstructionFromJson:obj withRoute:route.waypoints]];
        }
    }

    self->lastVisitedWaypointIndex = 0;
    return YES;
}

- (void)updateDistanceToNextTurn:(CLLocation *)loc {
    if (self.turnInstructions.count > 0) {
        SMTurnInstruction *nextTurn = [self.turnInstructions objectAtIndex:0];
        nextTurn.lengthInMeters = [self calculateDistanceToNextTurn:loc];
        nextTurn.lengthWithUnit = formatDistance(nextTurn.lengthInMeters);
        @synchronized(self.turnInstructions) {
            [self.turnInstructions setObject:nextTurn atIndexedSubscript:0];
        }
    }
}

- (NSData*) save {
    // TODO save visited locations and posibly some other info
    debugLog(@"Saving route");
    return [NSKeyedArchiver archivedDataWithRootObject:self.visitedLocations];
}

/*
 * Calculates distance from given location to next turn
 */
- (CGFloat)calculateDistanceToNextTurn:(CLLocation *)loc {
    if (self.turnInstructions.count == 0)
        return 0.0f;

    SMTurnInstruction *nextTurn = [self.turnInstructions objectAtIndex:0];

    // If first turn still hasn't been reached, return linear distance to it.
    if (self.pastTurnInstructions.count == 0)
        return [loc distanceFromLocation:nextTurn.loc];

    CGFloat distance = 0.0f;
    for (int i = lastVisitedWaypointIndex >= 0 ? lastVisitedWaypointIndex : 0; i < nextTurn.waypointsIndex; i++) {
        double d = [((CLLocation *)[self.waypoints objectAtIndex:i]) distanceFromLocation:[self.waypoints objectAtIndex:(i + 1)]];
        debugLog(@"[%d - %d] = %.1f", i, i + 1, d);
        distance += d;
    }

    debugLog(@"distance to next turn: %.1f", distance);
    return distance;
}

/*
 * Calculates distance from given location to next turn
 */
- (CGFloat)calculateDistanceLeft:(CLLocation *)loc {
    // TODO: for now this is called only after updateDistanceToNextTurn, so the updated distance to next turn is already
    // present in next turn's lengthInMeters. Use this to avoid calculating this twice: add distanceLeft member and implement
    // method  updateDistances, which would calculate both distances in one run.
    CGFloat distance = [self calculateDistanceToNextTurn:loc];

    // calculate distance from next turn to the end of the route
    for (int i = 1; i < self.turnInstructions.count; i++) {
        distance += ((SMTurnInstruction *)[self.turnInstructions objectAtIndex:i]).lengthInMeters;
    }

    debugLog(@"distance left: %.1f", distance);
    return distance;
}

- (CGFloat)calculateDistanceTraveled {
    if (self.tripDistance >= 0) {
        return self.tripDistance;
    }
    CGFloat distance = 0.0f;
    
    if ([self.visitedLocations count] > 1) {
        CLLocation * startLoc = [[self.visitedLocations objectAtIndex:0]  objectForKey:@"location"];
        for (int i = 1; i < [self.visitedLocations count]; i++) {
            distance += [[[self.visitedLocations objectAtIndex:i] objectForKey:@"location"] distanceFromLocation:startLoc];
            startLoc = [[self.visitedLocations objectAtIndex:i] objectForKey:@"location"];
        }
    }
    
    self.tripDistance = roundf(distance);
    
    return self.tripDistance;
}

- (CGFloat)calculateAverageSpeed {
    CGFloat distance = [self calculateDistanceTraveled];
    CGFloat avgSpeed = 0.0f;
    if ([self.visitedLocations count] > 1) {
        NSDate * startLoc = [[self.visitedLocations objectAtIndex:0] objectForKey:@"date"];
        NSDate * endLoc = [[self.visitedLocations lastObject] objectForKey:@"date"];
        if ([endLoc timeIntervalSinceDate:startLoc] > 0) {
            avgSpeed = distance / ([endLoc timeIntervalSinceDate:startLoc]);            
        }
    }
    self.averageSpeed = roundf(avgSpeed * 30.6)/10.0f;
    return self.averageSpeed;
}


- (NSString*)timePassed {
    if ([self.visitedLocations count] > 1) {
        NSDate * startDate = [[self.visitedLocations objectAtIndex:0] objectForKey:@"date"];
        NSDate * endDate = [[self.visitedLocations lastObject] objectForKey:@"date"];
        return formatTimePassed(startDate, endDate);
    }
    return @"";
}

- (CGFloat)calculateCaloriesBurned {
    if (self.caloriesBurned >= 0) {
        return self.caloriesBurned;
    }
    
    CGFloat avgSpeed = [self calculateAverageSpeed];
    CGFloat timeSpent = 0.0f;
    if ([self.visitedLocations count] > 1) {
        NSDate * startLoc = [[self.visitedLocations objectAtIndex:0] objectForKey:@"date"];
        NSDate * endLoc = [[self.visitedLocations lastObject] objectForKey:@"date"];
        timeSpent = [endLoc timeIntervalSinceDate:startLoc] / 3600.0f;
    }

    return self.caloriesBurned = caloriesBurned(avgSpeed, timeSpent);
}

#pragma mark - osrm request delegate

- (void)request:(SMRequestOSRM *)req failedWithError:(NSError *)error {
    if ([req.auxParam isEqualToString:@"routeRecalc"]) {
        self.recalculationInProgress = NO;
    }
}

- (void)request:(SMRequestOSRM *)req finishedWithResult:(id)res {
    if ([req.auxParam isEqualToString:@"startRoute"]) {
        NSString * response = [[NSString alloc] initWithData:req.responseData encoding:NSUTF8StringEncoding];
        if (response) {
            id jsonRoot = [[[SBJsonParser alloc] init] objectWithString:response];
            if (!jsonRoot || ([jsonRoot isKindOfClass:[NSDictionary class]] == NO) || ([[jsonRoot objectForKey:@"status"] intValue] != 0)) {
                if (self.delegate) {
                    [self.delegate routeNotFound];
                };
                return;
            }
            BOOL done = [self parseFromJson:jsonRoot delegate:nil];
            if (done) {
                approachingTurn = NO;
                self.tripDistance = 0.0f;
                @synchronized(self.pastTurnInstructions) {
                    self.pastTurnInstructions = [NSMutableArray array];
                }
                
                if ([SMLocationManager instance].hasValidLocation) {
                    [self updateDistanceToNextTurn:[SMLocationManager instance].lastValidLocation];
                }
                if (self.delegate && [self.delegate respondsToSelector:@selector(startRoute)]) {
                    [self.delegate startRoute];
                }
            }
        }

    } else if ([req.auxParam isEqualToString:@"routeRecalc"]) {
        NSString * response = [[NSString alloc] initWithData:req.responseData encoding:NSUTF8StringEncoding];
        NSLog(@"%@", response);
        if (response) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
                
                @synchronized(self) {
//                    SMRoute * rt = [[SMRoute alloc] init];
                    id jsonRoot = [[[SBJsonParser alloc] init] objectWithString:response];
                    if (!jsonRoot || ([jsonRoot isKindOfClass:[NSDictionary class]] == NO) || ([[jsonRoot objectForKey:@"status"] intValue] != 0)) {
                        if (self.delegate) {
                            [self.delegate routeNotFound];
                        };
                        return;
                    }
                    BOOL done = [self parseFromJson:jsonRoot delegate:nil];
                    if (done) {
                        approachingTurn = NO;
//                        @synchronized(self.pastTurnInstructions) {
//                            self.pastTurnInstructions = [NSMutableArray array];
//                        }

                        if ([SMLocationManager instance].hasValidLocation) {
                            [self updateDistanceToNextTurn:[SMLocationManager instance].lastValidLocation];
                        }

                        // Uncomment code below is if we want to display the previous part of the route.
////                        [self mergeWithRoute:rt];
//                        int i = 0;
//                        if (self.pastTurnInstructions && self.pastTurnInstructions.count > 0 && self.turnInstructions && self.turnInstructions.count > 0) {
//                            CLLocation *lastTurnLoc = nil; //((SMTurnInstruction *)[self.pastTurnInstructions lastObject]).loc;
//
//                            for (int i = 0, j = 0; j < self.turnInstructions.count;) {
//                                CLLocation *pastTurnLoc = ((SMTurnInstruction *)[self.pastTurnInstructions objectAtIndex:i]).loc;
//                                CLLocation *newTurnLoc = ((SMTurnInstruction *)[self.turnInstructions objectAtIndex:j]).loc;
//                                if (sameCoordinates(pastTurnLoc, newTurnLoc)) {
//                                    lastTurnLoc = pastTurnLoc;
//                                    i++;
//                                    j++;
//                                } else {
//                                    j++;
//                                }
//                                if (j == self.pastTurnInstructions.count) {
//                                    if (lastTurnLoc) {
//                                        break;
//                                    } else {
//                                        j = 0;
//                                        i++;
//                                    }
//                                }
//
//                            }
//
//                            [self.pastTurnInstructions removeAllObjects];
//
//                            if (lastTurnLoc) {
//                                // TODO replace loop with single transfer of i objects
//                                SMTurnInstruction *turn = [self.turnInstructions objectAtIndex:0];
//                                while (turn.loc.coordinate.latitude != lastTurnLoc.coordinate.latitude || turn.loc.coordinate.longitude != lastTurnLoc.coordinate.longitude) {
//                                    [self.pastTurnInstructions addObject:turn];
//                                    [self.turnInstructions removeObjectAtIndex:0];
//
//                                    if (!self.turnInstructions.count)
//                                        break;
//                                    turn = [self.turnInstructions objectAtIndex:0];
//                                    i++;
//                                }
//                                if (self.turnInstructions.count) {
//                                    [self.pastTurnInstructions addObject:turn];
//                                    [self.turnInstructions removeObjectAtIndex:0];
//                                }
//                            }
//                        }
                        // update segment
                        
//                        lastVisitedWaypointIndex = i;

                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (self.delegate && [self.delegate respondsToSelector:@selector(routeRecalculationDone)]) {
                                [self.delegate routeRecalculationDone];
                            }
                            [self.delegate updateRoute];
                            self.recalculationInProgress = NO;
                        });
                    }                    
                }
            });
        }
    }
}


@end
