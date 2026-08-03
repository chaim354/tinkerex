// makerjs@0.19.2 downloaded from https://ga.jspm.io/npm:makerjs@0.19.2/dist/index.js

import*as e from"clone";import*as t from"kdbush";import*as n from"graham_scan";import*as r from"bezier-js";var a=e;try{"default"in e&&(a=e.default)}catch(e){}var i=t;try{"default"in t&&(i=t.default)}catch(e){}var o=n;try{"default"in n&&(o=n.default)}catch(e){}var s=r;try{"default"in r&&(s=r.default)}catch(e){}var u=typeof globalThis!=="undefined"?globalThis:typeof self!=="undefined"?self:global;var l={};(function(e){e.version="debug";e.environmentTypes={BrowserUI:"browser",NodeJs:"node",WebWorker:"worker",Unknown:"unknown"};var t=Number.EPSILON||Math.pow(2,-52);function n(){var t=function(){return typeof self!=="undefined"?self:typeof u!=="undefined"?u:this||u||{}};var n=t();return n.self&&n.WorkerGlobalScope&&!n.window?e.environmentTypes.WebWorker:n.window&&n.document?e.environmentTypes.BrowserUI:n.global&&n.process?e.environmentTypes.NodeJs:e.environmentTypes.Unknown}e.environment=n();e.unitType={Centimeter:"cm",Foot:"foot",Inch:"inch",Meter:"m",Millimeter:"mm"};function r(e,t){var n=e.indexOf(t);return n<0?[e]:n>0?[e.substr(0,n),e.substr(n+1)]:["",e]}
/**
   * Split a decimal into its whole and fractional parts as strings.
   *
   * Example: get whole and fractional parts of 42.056
   * ```
   * makerjs.splitDecimal(42.056); //returns ["42", "056"]
   * ```
   *
   * @param n The number to split.
   * @returns Array of 2 strings when n contains a decimal point, or an array of one string when n is an integer.
   */function i(e){var t=e.toString();t.indexOf("e")>0&&(t=e.toFixed(20).match(/.*[^(0+$)]/)[0]);return r(t,".")}e.splitDecimal=i;
/**
   * Numeric rounding
   *
   * Example: round to 3 decimal places
   * ```
   * makerjs.round(3.14159, .001); //returns 3.142
   * ```
   *
   * @param n The number to round off.
   * @param accuracy Optional exemplar of number of decimal places.
   * @returns Rounded number.
   */function o(e,n){n===void 0&&(n=1e-7);if(e%1===0)return e;var r=1/n;return Math.round((e+t)*r)/r}e.round=o;
/**
   * Create a string representation of a route array.
   *
   * @param route Array of strings which are segments of a route.
   * @returns String of the flattened array.
   */function s(e){var t=[];for(var n=0;n<e.length;n++){var r=e[n];var a;a=n%2===0?(n>0?".":"")+r:JSON.stringify([r]);t.push(a)}return t.join("")}e.createRouteKey=s;
/**
   * Travel along a route inside of a model to extract a specific node in its tree.
   *
   * @param modelContext Model to travel within.
   * @param route String of a flattened route, or a string array of route segments.
   * @returns Model or Path object within the modelContext tree.
   */function l(t,n){if(!t||!n)return null;var r;r=Array.isArray(n)?n:JSON.parse(n);var a=r.slice();var i=t;var o=t.origin||[0,0];while(a.length){var s=a.shift();i=i[s];if(!i)return null;i.origin&&a.length&&(o=e.point.add(o,i.origin))}return{result:i,offset:o}}e.travel=l;var c=a;
/**
   * Clone an object.
   *
   * @param objectToClone The object to clone.
   * @returns A new clone of the original object.
   */function p(e){return c(e)}e.cloneObject=p;
/**
   * Copy the properties from one object to another object.
   *
   * Example:
   * ```
   * makerjs.extendObject({ abc: 123 }, { xyz: 789 }); //returns { abc: 123, xyz: 789 }
   * ```
   *
   * @param target The object to extend. It will receive the new properties.
   * @param other An object containing properties to merge in.
   * @returns The original object after merging.
   */function f(e,t){if(e&&t)for(var n in t)if(t.hasOwnProperty(n)&&typeof t[n]!=="undefined"){if(n==="__proto__"||n==="constructor"||n==="prototype")continue;e[n]=t[n]}return e}e.extendObject=f;
/**
   * Test to see if a variable is a function.
   *
   * @param value The object to test.
   * @returns True if the object is a function type.
   */function h(e){return typeof e==="function"}e.isFunction=h;
/**
   * Test to see if a variable is a number.
   *
   * @param value The object to test.
   * @returns True if the object is a number type.
   */function v(e){return typeof e==="number"}e.isNumber=v;
/**
   * Test to see if a variable is an object.
   *
   * @param value The object to test.
   * @returns True if the object is an object type.
   */function d(e){return typeof e==="object"}e.isObject=d;
/**
   * Test to see if an object implements the required properties of a point.
   *
   * @param item The item to test.
   */function g(e){return e&&Array.isArray(e)&&e.length==2&&v(e[0])&&v(e[1])}e.isPoint=g;
/**
   * Test to see if an object implements the required properties of a path.
   *
   * @param item The item to test.
   */function m(e){return e&&e.type&&g(e.origin)}e.isPath=m;
/**
   * Test to see if an object implements the required properties of a line.
   *
   * @param item The item to test.
   */function y(t){return m(t)&&t.type==e.pathType.Line&&g(t.end)}e.isPathLine=y;
/**
   * Test to see if an object implements the required properties of a circle.
   *
   * @param item The item to test.
   */function A(t){return m(t)&&t.type==e.pathType.Circle&&v(t.radius)}e.isPathCircle=A;
/**
   * Test to see if an object implements the required properties of an arc.
   *
   * @param item The item to test.
   */function P(t){return m(t)&&t.type==e.pathType.Arc&&v(t.radius)&&v(t.startAngle)&&v(t.endAngle)}e.isPathArc=P;
/**
   * Test to see if an object implements the required properties of an arc in a bezier curve.
   *
   * @param item The item to test.
   */function w(e){return P(e)&&d(e.bezierData)&&v(e.bezierData.startT)&&v(e.bezierData.endT)}e.isPathArcInBezierCurve=w;e.pathType={Line:"line",Circle:"circle",Arc:"arc",BezierSeed:"bezier-seed"};function T(e){return e&&(e.paths||e.models)}e.isModel=T;
/**
   * Test to see if an object implements the required properties of a chain.
   *
   * @param item The item to test.
   */function x(e){var t=e;return t&&t.links&&Array.isArray(t.links)&&v(t.pathLength)}e.isChain=x;var C=function(){function e(e,t){(this||u)._module=e;(this||u).$initial=t;for(var n in(this||u)._module)this._shadow(n);(this||u).$result=t}e.prototype._shadow=function(e){var t=this||u;(this||u)[e]=function(){return t._apply(t._module[e],arguments)}};e.prototype._apply=function(e,t){var n=[].slice.call(t);n.unshift((this||u).$result);(this||u).$result=e.apply(void 0,n);return this||u};e.prototype.$reset=function(){(this||u).$result=(this||u).$initial;return this||u};return e}();function b(t){return T(t)?new C(e.model,t):m(t)?new C(e.path,t):g(t)?new C(e.point,t):void 0}e.$=b})(c||(c={}));l=c;(function(e){(function(t){function n(t){return e.splitDecimal(t)[1]}function r(t,n){return n?+(e.splitDecimal(t)[0]+"."+n):t}function a(e,t){return e<0&&t<0||e>0&&t>0?r(t,n(e)):t}
/**
     * Ensures an angle is not greater than 360
     *
     * @param angleInDegrees Angle in degrees.
     * @returns Same polar angle but not greater than 360 degrees.
     */function i(e){var t=Math.floor(e/360);if(t===0)return e;var n=e-360*t;return a(e,n)}t.noRevolutions=i;
/**
     * Convert an angle from degrees to radians.
     *
     * @param angleInDegrees Angle in degrees.
     * @returns Angle in radians.
     */function o(e){return i(e)*Math.PI/180}t.toRadians=o;
/**
     * Convert an angle from radians to degrees.
     *
     * @param angleInRadians Angle in radians.
     * @returns Angle in degrees.
     */function s(e){return e*180/Math.PI}t.toDegrees=s;
/**
     * Get an arc's end angle, ensured to be greater than its start angle.
     *
     * @param arc An arc path object.
     * @returns End angle of arc.
     */function u(e){if(e.endAngle<e.startAngle){var t=Math.ceil((e.startAngle-e.endAngle)/360);var n=t*360+e.endAngle;return a(e.endAngle,n)}return e.endAngle}t.ofArcEnd=u;
/**
     * Get the angle in the middle of an arc's start and end angles.
     *
     * @param arc An arc path object.
     * @param ratio Optional number between 0 and 1 specifying percentage between start and end angles. Default is .5
     * @returns Middle angle of arc.
     */function l(e,t){t===void 0&&(t=.5);return e.startAngle+c(e)*t}t.ofArcMiddle=l;
/**
     * Total angle of an arc between its start and end angles.
     *
     * @param arc The arc to measure.
     * @returns Angle of arc.
     */function c(n){var r=t.ofArcEnd(n);var a=r-n.startAngle;return e.round(a)>360?i(a):a}t.ofArcSpan=c;
/**
     * Angle of a line path.
     *
     * @param line The line path to find the angle of.
     * @returns Angle of the line path, in degrees.
     */function p(e){return i(s(h(e.origin,e.end)))}t.ofLineInDegrees=p;
/**
     * Angle of a line through a point, in degrees.
     *
     * @param pointToFindAngle The point to find the angle.
     * @param origin Point of origin of the angle.
     * @returns Angle of the line throught the point, in degrees.
     */function f(e,t){return s(h(e,t))}t.ofPointInDegrees=f;
/**
     * Angle of a line through a point, in radians.
     *
     * @param pointToFindAngle The point to find the angle.
     * @param origin Point of origin of the angle.
     * @returns Angle of the line throught the point, in radians.
     */function h(t,n){var r=e.point.subtract(n,t);var a=r[0];var i=r[1];return Math.atan2(-i,-a)+Math.PI}t.ofPointInRadians=h;
/**
     * Mirror an angle on either or both x and y axes.
     *
     * @param angleInDegrees The angle to mirror.
     * @param mirrorX Boolean to mirror on the x axis.
     * @param mirrorY Boolean to mirror on the y axis.
     * @returns Mirrored angle.
     */function v(e,t,n){n&&(e=360-e);t&&(e=(e<180?180:540)-e);return e}t.mirror=v;var d={};d[e.pathType.Arc]=function(t,n,r){var a=n!=r;var i=a?t.endAngle-90:t.startAngle+90;var o=e.point.fromArc(t)[a?1:0];var s=e.point.rotate(e.point.add(o,[t.radius,0]),i,o);return new e.paths.Line(n?[s,o]:[o,s])};d[e.pathType.Line]=function(t,n,r){return r?new e.paths.Line(t.end,t.origin):t};function g(e,t){if(e){var n=e.walkedPath.pathContext;var r=d[n.type];if(r)return r(n,t,e.reversed)}}
/**
     * Get the angle of a joint between 2 chain links.
     *
     * @param linkA First chain link.
     * @param linkB Second chain link.
     * @returns Angle between chain links.
     */function m(e,t){if(arguments.length<2)return null;var n=[e,t].map((function(e,t){return g(e,t===0)}));var r=i(p(n[1])-p(n[0]));r>180&&(r-=360);return r}t.ofChainLinkJoint=m})(e.angle||(e.angle={}))})(c||(c={}));(function(e){(function(t){
/**
     * Add two points together and return the result as a new point object.
     *
     * @param a First point.
     * @param b Second point.
     * @param subtract Optional boolean to subtract instead of add.
     * @returns A new point object.
     */
function n(e,t,n){var r=a(e);if(!t)return r;for(var i=2;i--;)n?r[i]-=t[i]:r[i]+=t[i];return r}t.add=n;
/**
     * Get the average of two points.
     *
     * @param a First point.
     * @param b Second point.
     * @returns New point object which is the average of a and b.
     */function r(e,t){function n(n){return(e[n]+t[n])/2}return[n(0),n(1)]}t.average=r;
/**
     * Clone a point into a new point.
     *
     * @param pointToClone The point to clone.
     * @returns A new point with same values as the original.
     */function a(e){return e?[e[0],e[1]]:t.zero()}t.clone=a;
/**
     * From an array of points, find the closest point to a given reference point.
     *
     * @param referencePoint The reference point.
     * @param pointOptions Array of points to choose from.
     * @returns The first closest point from the pointOptions.
     */function i(t,n){var r={index:0,distance:-1};for(var a=0;a<n.length;a++){var i=e.measure.pointDistance(t,n[a]);if(r.distance==-1||i<r.distance){r.distance=i;r.index=a}}return n[r.index]}t.closest=i;var o={};o[Math.PI/2]=true;o[3*Math.PI/2]=true;var s={};s[Math.PI]=true;s[2*Math.PI]=true;
/**
     * Get a point from its polar coordinates.
     *
     * @param angleInRadians The angle of the polar coordinate, in radians.
     * @param radius The radius of the polar coordinate.
     * @returns A new point object.
     */function u(t,n){return[t in o?0:e.round(n*Math.cos(t)),t in s?0:e.round(n*Math.sin(t))]}t.fromPolar=u;
/**
     * Get a point on a circle or arc path, at a given angle.
     * @param angleInDegrees The angle at which you want to find the point, in degrees.
     * @param circle A circle or arc.
     * @returns A new point object.
     */function l(t,r){return n(r.origin,u(e.angle.toRadians(t),r.radius))}t.fromAngleOnCircle=l;
/**
     * Get the two end points of an arc path.
     *
     * @param arc The arc path object.
     * @returns Array with 2 elements: [0] is the point object corresponding to the start angle, [1] is the point object corresponding to the end angle.
     */function c(e){return[l(e.startAngle,e),l(e.endAngle,e)]}t.fromArc=c;var p={};p[e.pathType.Arc]=function(e){return t.fromArc(e)};p[e.pathType.Line]=function(e){return[e.origin,e.end]};p[e.pathType.BezierSeed]=p[e.pathType.Line];
/**
     * Get the two end points of a path.
     *
     * @param pathContext The path object.
     * @returns Array with 2 elements: [0] is the point object corresponding to the origin, [1] is the point object corresponding to the end.
     */function f(e,t){var r=null;var a=p[e.type];if(a){r=a(e);t&&(r=r.map((function(e){return n(e,t)})))}return r}t.fromPathEnds=f;function h(e,t){var n=e.origin[0];var r=t.slope*n+t.yIntercept;return[n,r]}
/**
     * Calculates the intersection of slopes of two lines.
     *
     * @param lineA First line to use for slope.
     * @param lineB Second line to use for slope.
     * @param options Optional IPathIntersectionOptions.
     * @returns point of intersection of the two slopes, or null if the slopes did not intersect.
     */function v(t,n,r){r===void 0&&(r={});var a=e.measure.lineSlope(t);var i=e.measure.lineSlope(n);if(e.measure.isSlopeParallel(a,i)){e.measure.isSlopeEqual(a,i)&&(r.out_AreOverlapped=e.measure.isLineOverlapping(t,n,r.excludeTangents));return null}var o;if(a.hasSlope)if(i.hasSlope){var s=(i.yIntercept-a.yIntercept)/(a.slope-i.slope);var u=a.slope*s+a.yIntercept;o=[s,u]}else o=h(n,a);else o=h(t,i);return o}t.fromSlopeIntersection=v;function d(n,r){return t.add(n.origin,t.fromPolar(e.angle.toRadians(r),n.radius))}var g={};g[e.pathType.Arc]=function(t,n){var r=e.angle.ofArcMiddle(t,n);return d(t,r)};g[e.pathType.Circle]=function(e,t){return d(e,360*t)};g[e.pathType.Line]=function(e,t){function n(e,n){return e+(n-e)*t}return[n(e.origin[0],e.end[0]),n(e.origin[1],e.end[1])]};g[e.pathType.BezierSeed]=function(t,n){return e.models.BezierCurve.computePoint(t,n)};
/**
     * Get the middle point of a path.
     *
     * @param pathContext The path object.
     * @param ratio Optional ratio (between 0 and 1) of point along the path. Default is .5 for middle.
     * @returns Point on the path, in the middle of the path.
     */function m(e,t){t===void 0&&(t=.5);var n=null;var r=g[e.type];r&&(n=r(e,t));return n}t.middle=m;
/**
     * Create a clone of a point, mirrored on either or both x and y axes.
     *
     * @param pointToMirror The point to mirror.
     * @param mirrorX Boolean to mirror on the x axis.
     * @param mirrorY Boolean to mirror on the y axis.
     * @returns Mirrored point.
     */function y(e,t,n){var r=a(e);t&&(r[0]=-r[0]);n&&(r[1]=-r[1]);return r}t.mirror=y;
/**
     * Round the values of a point.
     *
     * @param pointContext The point to serialize.
     * @param accuracy Optional exemplar number of decimal places.
     * @returns A new point with the values rounded.
     */function A(t,n){return[e.round(t[0],n),e.round(t[1],n)]}t.rounded=A;
/**
     * Rotate a point.
     *
     * @param pointToRotate The point to rotate.
     * @param angleInDegrees The amount of rotation, in degrees.
     * @param rotationOrigin The center point of rotation.
     * @returns A new point.
     */function P(t,r,a){a===void 0&&(a=[0,0]);var i=e.angle.ofPointInRadians(a,t);var o=e.measure.pointDistance(a,t);var s=u(i+e.angle.toRadians(r),o);return n(a,s)}t.rotate=P;
/**
     * Scale a point's coordinates.
     *
     * @param pointToScale The point to scale.
     * @param scaleValue The amount of scaling.
     * @returns A new point.
     */function w(e,t){var n=a(e);for(var r=2;r--;)n[r]*=t;return n}t.scale=w;
/**
     * Distort a point's coordinates.
     *
     * @param pointToDistort The point to distort.
     * @param scaleX The amount of x scaling.
     * @param scaleY The amount of y scaling.
     * @returns A new point.
     */function T(e,t,n){return[e[0]*t,e[1]*n]}t.distort=T;
/**
     * Subtract a point from another point, and return the result as a new point. Shortcut to Add(a, b, subtract = true).
     *
     * @param a First point.
     * @param b Second point.
     * @returns A new point object.
     */function x(e,t){return n(e,t,true)}t.subtract=x;
/**
     * A point at 0,0 coordinates.
     * NOTE: It is important to call this as a method, with the empty parentheses.
     *
     * @returns A new point.
     */function C(){return[0,0]}t.zero=C})(e.point||(e.point={}))})(c||(c={}));(function(e){(function(t){
/**
     * Add a path to a model. This is basically equivalent to:
     * ```
     * parentModel.paths[pathId] = childPath;
     * ```
     * with additional checks to make it safe for cascading.
     *
     * @param childPath The path to add.
     * @param parentModel The model to add to.
     * @param pathId The id of the path.
     * @param overwrite Optional flag to overwrite any path referenced by pathId. Default is false, which will create an id similar to pathId.
     * @returns The original path (for cascading).
     */
function n(t,n,r,a){a===void 0&&(a=false);e.model.addPath(n,t,r,a);return t}t.addTo=n;function r(e,t){e&&t&&typeof e.layer!=="undefined"&&(t.layer=e.layer);e&&t&&"bezierData"in e&&(t.bezierData=e.bezierData)}var a={};a[e.pathType.Circle]=function(e,t,n){t.radius=e.radius};a[e.pathType.Arc]=function(t,n,r){a[e.pathType.Circle](t,n,r);n.startAngle=t.startAngle;n.endAngle=t.endAngle};a[e.pathType.Line]=function(t,n,r){n.end=e.point.add(t.end,r)};a[e.pathType.BezierSeed]=function(t,n,r){a[e.pathType.Line](t,n,r);n.controls=t.controls.map((function(t){return e.point.add(t,r)}))};
/**
     * Create a clone of a path. This is faster than cloneObject.
     *
     * @param pathToClone The path to clone.
     * @param offset Optional point to move path a relative distance.
     * @returns Cloned path.
     */function i(t,n){var i={type:t.type,origin:e.point.add(t.origin,n)};var o=a[t.type];o&&o(t,i,n);r(t,i);return i}t.clone=i;
/**
     * Copy the schema properties of one path to another.
     *
     * @param srcPath The source path to copy property values from.
     * @param destPath The destination path to copy property values to.
     * @returns The source path.
     */function o(t,n){var i=a[t.type];if(i){n.origin=e.point.clone(t.origin);i(t,n)}r(t,n);return t}t.copyProps=o;var s={};s[e.pathType.Line]=function(t,n,r,a){return new e.paths.Line(n,e.point.mirror(t.end,r,a))};s[e.pathType.Circle]=function(t,n,r,a){return new e.paths.Circle(n,t.radius)};s[e.pathType.Arc]=function(t,n,r,a){var i=e.angle.mirror(t.startAngle,r,a);var o=e.angle.mirror(e.angle.ofArcEnd(t),r,a);var s=r!=a;return new e.paths.Arc(n,t.radius,s?o:i,s?i:o)};s[e.pathType.BezierSeed]=function(t,n,r,a){var i=s[e.pathType.Line](t,n,r,a);i.type=e.pathType.BezierSeed;i.controls=t.controls.map((function(t){return e.point.mirror(t,r,a)}));return i};
/**
     * Set the layer of a path. This is equivalent to:
     * ```
     * pathContext.layer = layer;
     * ```
     *
     * @param pathContext The path to set the layer.
     * @param layer The layer name.
     * @returns The original path (for cascading).
     */function u(e,t){e.layer=t;return e}t.layer=u;
/**
     * Create a clone of a path, mirrored on either or both x and y axes.
     *
     * @param pathToMirror The path to mirror.
     * @param mirrorX Boolean to mirror on the x axis.
     * @param mirrorY Boolean to mirror on the y axis.
     * @returns Mirrored path.
     */function l(t,n,a){var i=null;if(t){var o=e.point.mirror(t.origin,n,a);var u=s[t.type];u&&(i=u(t,o,n,a))}r(t,i);return i}t.mirror=l;var c={};c[e.pathType.Line]=function(t,n){var r=e.point.subtract(t.end,t.origin);t.end=e.point.add(n,r)};
/**
     * Move a path to an absolute point.
     *
     * @param pathToMove The path to move.
     * @param origin The new origin for the path.
     * @returns The original path (for cascading).
     */function p(e,t){if(e){var n=c[e.type];n&&n(e,t);e.origin=t}return e}t.move=p;var f={};f[e.pathType.Line]=function(t,n,r){t.end=e.point.add(t.end,n,r)};f[e.pathType.BezierSeed]=function(t,n,r){f[e.pathType.Line](t,n,r);t.controls=t.controls.map((function(t){return e.point.add(t,n,r)}))};
/**
     * Move a path's origin by a relative amount.
     *
     * @param pathToMove The path to move.
     * @param delta The x & y adjustments as a point object.
     * @param subtract Optional boolean to subtract instead of add.
     * @returns The original path (for cascading).
     */function h(t,n,r){if(t&&n){t.origin=e.point.add(t.origin,n,r);var a=f[t.type];a&&a(t,n,r)}return t}t.moveRelative=h;
/**
     * Move some paths relatively during a task execution, then unmove them.
     *
     * @param pathsToMove The paths to move.
     * @param deltas The x & y adjustments as a point object array.
     * @param task The function to call while the paths are temporarily moved.
     */function v(e,t,n){var r=false;function a(e,n){t[n]&&h(e,t[n],r)}e.map(a);n();r=true;e.map(a)}t.moveTemporary=v;var d={};d[e.pathType.Line]=function(t,n,r){t.end=e.point.rotate(t.end,n,r)};d[e.pathType.Arc]=function(t,n,r){t.startAngle=e.angle.noRevolutions(t.startAngle+n);t.endAngle=e.angle.noRevolutions(t.endAngle+n)};d[e.pathType.BezierSeed]=function(t,n,r){d[e.pathType.Line](t,n,r);t.controls=t.controls.map((function(t){return e.point.rotate(t,n,r)}))};
/**
     * Rotate a path.
     *
     * @param pathToRotate The path to rotate.
     * @param angleInDegrees The amount of rotation, in degrees.
     * @param rotationOrigin The center point of rotation.
     * @returns The original path (for cascading).
     */function g(t,n,r){r===void 0&&(r=[0,0]);if(!t||!n)return t;t.origin=e.point.rotate(t.origin,n,r);var a=d[t.type];a&&a(t,n,r);return t}t.rotate=g;var m={};m[e.pathType.Line]=function(t,n){t.end=e.point.scale(t.end,n)};m[e.pathType.BezierSeed]=function(t,n){m[e.pathType.Line](t,n);t.controls=t.controls.map((function(t){return e.point.scale(t,n)}))};m[e.pathType.Circle]=function(e,t){e.radius*=t};m[e.pathType.Arc]=m[e.pathType.Circle];
/**
     * Scale a path.
     *
     * @param pathToScale The path to scale.
     * @param scaleValue The amount of scaling.
     * @returns The original path (for cascading).
     */function y(t,n){if(!t||n===1||!n)return t;t.origin=e.point.scale(t.origin,n);var r=m[t.type];r&&r(t,n);return t}t.scale=y;var A={};A[e.pathType.Arc]=function(t,n,r){return new e.models.EllipticArc(t,n,r)};A[e.pathType.Circle]=function(t,n,r){var a=new e.models.Ellipse(t.radius*n,t.radius*r);a.origin=e.point.distort(t.origin,n,r);return a};A[e.pathType.Line]=function(t,n,r){return new e.paths.Line([t.origin,t.end].map((function(t){return e.point.distort(t,n,r)})))};A[e.pathType.BezierSeed]=function(t,n,r){var a=e.point.distort;return{type:e.pathType.BezierSeed,origin:a(t.origin,n,r),controls:t.controls.map((function(e){return a(e,n,r)})),end:a(t.end,n,r)}};
/**
     * Distort a path - scale x and y individually.
     *
     * @param pathToDistort The path to distort.
     * @param scaleX The amount of x scaling.
     * @param scaleY The amount of y scaling.
     * @returns A new IModel (for circles and arcs) or IPath (for lines and bezier seeds).
     */function P(e,t,n){if(!e||!t||!n)return null;var r=A[e.type];if(r){var a=r(e,t,n);typeof e.layer!=="undefined"&&(a.layer=e.layer);return a}return null}t.distort=P;
/**
     * Connect 2 lines at their slope intersection point.
     *
     * @param lineA First line to converge.
     * @param lineB Second line to converge.
     * @param useOriginA Optional flag to converge the origin point of lineA instead of the end point.
     * @param useOriginB Optional flag to converge the origin point of lineB instead of the end point.
     * @returns point of convergence.
     */function w(t,n,r,a){var i=e.point.fromSlopeIntersection(t,n);if(i){var o=[t,n];var s=[r,a];arguments.length===2&&o.forEach((function(t,n){s[n]=e.point.closest(i,[t.origin,t.end])===t.origin}));function u(e,t){var n;n=t?e.origin:e.end;n[0]=i[0];n[1]=i[1]}o.forEach((function(e,t){u(e,s[t])}))}return i}t.converge=w;var T={};T[e.pathType.Arc]=function(t,n,r,a){var i=e.angle.ofArcSpan(t);var o=(n+r)*i/n-i;a?t.startAngle-=o:t.endAngle+=o};T[e.pathType.Circle]=function(e,t,n,r){e.radius*=(t+n)/t};T[e.pathType.Line]=function(t,n,r,a){var i=e.point.scale(e.point.subtract(t.end,t.origin),r/n);a?t.origin=e.point.subtract(t.origin,i):t.end=e.point.add(t.end,i)};
/**
     * Alter a path by lengthening or shortening it.
     *
     * @param pathToAlter Path to alter.
     * @param distance Numeric amount of length to add or remove from the path. Use a positive number to lengthen, negative to shorten. When shortening: this function will not alter the path and will return null if the resulting path length is less than or equal to zero.
     * @param useOrigin Optional flag to alter from the origin instead of the end of the path.
     * @returns The original path (for cascading), or null if the path could not be altered.
     */function x(t,n,r){r===void 0&&(r=false);if(!t||!n)return null;var a=T[t.type];if(a){var i=e.measure.pathLength(t);if(!i||-n>=i)return null;a(t,i,n,r);return t}return null}t.alterLength=x;
/**
     * Get points along a path.
     *
     * @param pathContext Path to get points from.
     * @param numberOfPoints Number of points to divide the path.
     * @returns Array of points which are on the path spread at a uniform interval.
     */function C(t,n){if(n==1)return[e.point.middle(t)];var r=[];var a=n;t.type!=e.pathType.Circle&&a--;for(var i=0;i<n;i++)r.push(e.point.middle(t,i/a));return r}t.toPoints=C;var b={};b[e.pathType.Line]=function(e){return 2};b[e.pathType.Circle]=function(t,n){var r=e.measure.pathLength(t);if(!r)return 0;n=n||r;return Math.max(8,Math.ceil(r/(n||r)))};b[e.pathType.Arc]=function(t,n){var r=e.measure.pathLength(t);if(!r)return 0;var a=Math.ceil(e.angle.ofArcSpan(t)/45)+1;return Math.max(a,Math.ceil(r/(n||r)))};
/**
     * Get key points (a minimal a number of points) along a path.
     *
     * @param pathContext Path to get points from.
     * @param maxArcFacet Optional maximum length between points on an arc or circle.
     * @returns Array of points which are on the path.
     */function k(t,n){if(t.type==e.pathType.BezierSeed){var r=new e.models.BezierCurve(t);var a;e.model.findChains(r,(function(t,n,r){if(t.length==1){var i=t[0];switch(i.links[0].walkedPath.pathId){case"arc_0":case"line_0":break;default:e.chain.reverse(i)}a=e.chain.toKeyPoints(i)}else n.length===1&&(a=k(n[0].pathContext))}));return a}var i=b[t.type];if(i){var o=i(t,n);if(o)return C(t,o)}return[]}t.toKeyPoints=k;
/**
     * Center a path at [0, 0].
     *
     * @param pathToCenter The path to center.
     * @returns The original path (for cascading).
     */function L(t){var n=e.measure.pathExtents(t);var r=e.point.average(n.high,n.low);var a=e.point.subtract(t.origin||[0,0],r);p(t,a);return t}t.center=L;
/**
     * Move a path so its bounding box begins at [0, 0].
     *
     * @param pathToZero The path to zero.
     * @returns The original path (for cascading).
     */function M(t){var n=e.measure.pathExtents(t);var r=e.point.subtract(t.origin||[0,0],n.low);p(t,r);return t}t.zero=M})(e.path||(e.path={}))})(c||(c={}));(function(e){(function(t){var n={};n[e.pathType.Arc]=function(t,n){var r=e.angle.ofPointInDegrees(t.origin,n);if(e.measure.isAngleEqual(r,t.startAngle)||e.measure.isAngleEqual(r,t.endAngle))return null;function a(){var n=e.angle.noRevolutions(t.startAngle);var a=n+e.angle.ofArcEnd(t)-t.startAngle;var i=[0,1,-1];for(var o=0;o<i.length;o++){var s=360*i[o];if(e.measure.isBetween(r+s,n,a,true))return t.startAngle+r+s-n}return null}var i=a();if(i==null)return null;var o=t.endAngle;t.endAngle=i;var s=e.cloneObject(t);s.startAngle=i;s.endAngle=o;return s};n[e.pathType.Circle]=function(t,n){t.type=e.pathType.Arc;var r=t;var a=e.angle.ofPointInDegrees(t.origin,n);r.startAngle=a;r.endAngle=a+360;return null};n[e.pathType.Line]=function(t,n){if(!e.measure.isBetweenPoints(n,t,true))return null;var r=t.end;t.end=n;var a=e.cloneObject(t);a.origin=n;a.end=r;return a};
/**
     * Breaks a path in two. The supplied path will end at the supplied pointOfBreak,
     * a new path is returned which begins at the pointOfBreak and ends at the supplied path's initial end point.
     * For Circle, the original path will be converted in place to an Arc, and null is returned.
     *
     * @param pathToBreak The path to break.
     * @param pointOfBreak The point at which to break the path.
     * @returns A new path of the same type, when path type is line or arc. Returns null for circle.
     */function r(e,t){if(e&&t){var r=n[e.type];if(r){var a=r(e,t);a&&"layer"in e&&(a.layer=e.layer);return a}}return null}t.breakAtPoint=r})(e.path||(e.path={}))})(c||(c={}));(function(e){(function(t){var n=function(){function t(){var t=[];for(var n=0;n<arguments.length;n++)t[n]=arguments[n];var a,i;function o(n){var r=e.angle.ofPointInDegrees(n,t[p?1:0]);var a=e.angle.ofPointInDegrees(n,t[p?0:1]);a<r&&(a+=360);return{origin:n,startAngle:r,endAngle:a,size:a-r}}switch(t.length){case 5:var s=t[0];var l=t[1];(this||u).radius=t[2];var c=t[3];var p=t[4];var f;var h=e.measure.pointDistance(s,l)/2;if(e.round((this||u).radius-h)<=0){(this||u).radius=h;f=o(e.point.average(s,l))}else{var v=(i=(a=e.path.intersection(new r(s,(this||u).radius),new r(l,(this||u).radius)))===null||a===void 0?void 0:a.intersectionPoints)!==null&&i!==void 0?i:[s,l];var d=[];for(var g=v.length;g--;){f=o(v[g]);d.length==0||f.size>d[0].size?d.push(f):d.unshift(f)}var m=c?1:0;f=d[m]}(this||u).origin=f.origin;(this||u).startAngle=f.startAngle;(this||u).endAngle=f.endAngle;break;case 4:(this||u).origin=t[0];(this||u).radius=t[1];(this||u).startAngle=t[2];(this||u).endAngle=t[3];break;case 3:if(e.isPoint(t[2])){r.apply(this||u,t);var y=[];for(var A=0;A<3;A++)y.push(e.angle.ofPointInDegrees((this||u).origin,t[A]));(this||u).startAngle=y[0];(this||u).endAngle=y[2];if(!e.measure.isBetweenArcAngles(y[1],this||u,false)){(this||u).startAngle=y[2];(this||u).endAngle=y[0]}break}case 2:p=t[2];r.call(this||u,t[0],t[1]);(this||u).startAngle=e.angle.ofPointInDegrees((this||u).origin,t[p?1:0]);(this||u).endAngle=e.angle.ofPointInDegrees((this||u).origin,t[p?0:1]);break}(this||u).type=e.pathType.Arc}return t}();t.Arc=n;var r=function(){function t(){var t=[];for(var n=0;n<arguments.length;n++)t[n]=arguments[n];(this||u).type=e.pathType.Circle;switch(t.length){case 1:(this||u).origin=[0,0];(this||u).radius=t[0];break;case 2:if(e.isNumber(t[1])){(this||u).origin=t[0];(this||u).radius=t[1]}else{(this||u).origin=e.point.average(t[0],t[1]);(this||u).radius=e.measure.pointDistance((this||u).origin,t[0])}break;default:var r=[new a(t[0],t[1]),new a(t[1],t[2])];var i=[];for(var o=2;o--;){var s=e.point.middle(r[o]);i.push(e.path.rotate(r[o],90,s))}var l=e.point.fromSlopeIntersection(i[0],i[1]);if(!l)throw"invalid parameters - attempted to construct a circle from 3 points on a line: "+JSON.stringify(t);(this||u).origin=l;(this||u).radius=e.measure.pointDistance((this||u).origin,t[0]);break}}return t}();t.Circle=r;var a=function(){function t(){var t=[];for(var n=0;n<arguments.length;n++)t[n]=arguments[n];(this||u).type=e.pathType.Line;switch(t.length){case 1:var r=t[0];(this||u).origin=r[0];(this||u).end=r[1];break;case 2:(this||u).origin=t[0];(this||u).end=t[1];break}}return t}();t.Line=a;
/**
     * Class for chord, which is simply a line path that connects the endpoints of an arc.
     *
     * @param arc Arc to use as the basic for the chord.
     */var i=function(){function t(t){var n=e.point.fromArc(t);(this||u).type=e.pathType.Line;(this||u).origin=n[0];(this||u).end=n[1]}return t}();t.Chord=i;
/**
     * Class for a parallel line path.
     *
     * @param toLine A line to be parallel to.
     * @param distance Distance between parallel and original line.
     * @param nearPoint Any point to determine which side of the line to place the parallel.
     */var o=function(){function t(t,n,r){(this||u).type=e.pathType.Line;(this||u).origin=e.point.clone(t.origin);(this||u).end=e.point.clone(t.end);var a=e.angle.ofLineInDegrees(this||u);function i(i){var o=e.point.add(t.origin,e.point.fromPolar(e.angle.toRadians(a+i),n));return{origin:o,nearness:e.measure.pointDistance(o,r)}}var o=[i(-90),i(90)];var s=o[0].nearness<o[1].nearness?o[0].origin:o[1].origin;e.path.move(this||u,s)}return t}();t.Parallel=o})(e.paths||(e.paths={}))})(c||(c={}));(function(e){(function(t){
/**
     * Add a Caption object to a model.
     * @param modelContext The model to add to.
     * @param text Text to add.
     * @param leftAnchorPoint Optional Point on left side middle of text.
     * @param rightAnchorPoint Optional Point on right side middle of text.
     * @returns The original model (for cascading).
     */
function n(t,n,r,a){r||(r=e.point.zero());a||(a=e.point.clone(r));t.caption={text:n,anchor:new e.paths.Line(r,a)};return t}t.addCaption=n;
/**
     * Add a path as a child. This is basically equivalent to:
     * ```
     * parentModel.paths[childPathId] = childPath;
     * ```
     * with additional checks to make it safe for cascading.
     *
     * @param modelContext The model to add to.
     * @param pathContext The path to add.
     * @param pathId The id of the path.
     * @param overWrite Optional flag to overwrite any path referenced by pathId. Default is false, which will create an id similar to pathId.
     * @returns The original model (for cascading).
     */function r(e,t,n,r){r===void 0&&(r=false);var a=r?n:p(e,n);e.paths=e.paths||{};e.paths[a]=t;return e}t.addPath=r;
/**
     * Add a model as a child. This is basically equivalent to:
     * ```
     * parentModel.models[childModelId] = childModel;
     * ```
     * with additional checks to make it safe for cascading.
     *
     * @param parentModel The model to add to.
     * @param childModel The model to add.
     * @param childModelId The id of the child model.
     * @param overWrite Optional flag to overwrite any model referenced by childModelId. Default is false, which will create an id similar to childModelId.
     * @returns The original model (for cascading).
     */function a(e,t,n,r){r===void 0&&(r=false);var a=r?n:c(e,n);e.models=e.models||{};e.models[a]=t;return e}t.addModel=a;
/**
     * Add a model as a child of another model. This is basically equivalent to:
     * ```
     * parentModel.models[childModelId] = childModel;
     * ```
     * with additional checks to make it safe for cascading.
     *
     * @param childModel The model to add.
     * @param parentModel The model to add to.
     * @param childModelId The id of the child model.
     * @param overWrite Optional flag to overwrite any model referenced by childModelId. Default is false, which will create an id similar to childModelId.
     * @returns The original model (for cascading).
     */function i(e,t,n,r){r===void 0&&(r=false);a(t,e,n,r);return e}t.addTo=i;
/**
     * Clone a model. Alias of makerjs.cloneObject(modelToClone)
     *
     * @param modelToClone The model to clone.
     * @returns A clone of the model you passed.
     */function o(t){return e.cloneObject(t)}t.clone=o;
/**
     * Count the number of child models within a given model.
     *
     * @param modelContext The model containing other models.
     * @returns Number of child models.
     */function s(e){var t=0;if(e.models)for(var n in e.models)t++;return t}t.countChildModels=s;
/**
     * Gets all Caption objects, in absolute position, in this model and its children.
     * @param modelContext The model to search for Caption objects.
     * @returns Array of Caption objects.
     */function u(n){var r=[];function a(t,n,a){t.caption&&r.push({text:t.caption.text,anchor:e.path.clone(t.caption.anchor,e.point.add(t.origin,n)),layer:t.caption.anchor.layer||a})}a(n,n.origin,n.layer);t.walk(n,{afterChildWalk:function(e){return a(e.childModel,e.offset,e.layer)}});return r}t.getAllCaptionsOffset=u;function l(e,t){if(!e)return t;var n=0;var r=t;while(r in e){n++;r=[t,n].join("_")}return r}
/**
     * Get an unused id in the models map with the same prefix.
     *
     * @param modelContext The model containing the models map.
     * @param modelId The id to use directly (if unused), or as a prefix.
     */function c(e,t){return l(e.models,t)}t.getSimilarModelId=c;
/**
     * Get an unused id in the paths map with the same prefix.
     *
     * @param modelContext The model containing the paths map.
     * @param pathId The id to use directly (if unused), or as a prefix.
     */function p(e,t){return l(e.paths,t)}t.getSimilarPathId=p;
/**
     * Set the layer of a model. This is equivalent to:
     * ```
     * modelContext.layer = layer;
     * ```
     *
     * @param modelContext The model to set the layer.
     * @param layer The layer name.
     * @returns The original model (for cascading).
     */function f(e,t){e.layer=t;return e}t.layer=f;
/**
     * Moves all of a model's children (models and paths, recursively) in reference to a single common origin. Useful when points between children need to connect to each other.
     *
     * @param modelToOriginate The model to originate.
     * @param origin Optional offset reference point.
     * @returns The original model (for cascading).
     */function h(t,n){function r(t,n){if(t){var a=e.point.add(t.origin,n);t.type===e.models.BezierCurve.typeName&&e.path.moveRelative(t.seed,a);if(t.paths)for(var i in t.paths)e.path.moveRelative(t.paths[i],a);if(t.models)for(var i in t.models)r(t.models[i],a);t.caption&&e.path.moveRelative(t.caption.anchor,a);t.origin=e.point.zero()}}r(t,n?e.point.subtract([0,0],n):[0,0]);n&&(t.origin=n);return t}t.originate=h;
/**
     * Center a model at [0, 0].
     *
     * @param modelToCenter The model to center.
     * @param centerX Boolean to center on the x axis. Default is true.
     * @param centerY Boolean to center on the y axis. Default is true.
     * @returns The original model (for cascading).
     */function v(t,n,r){n===void 0&&(n=true);r===void 0&&(r=true);var a=e.measure.modelExtents(t);var i=t.origin||[0,0];n&&(i[0]-=a.center[0]);r&&(i[1]-=a.center[1]);t.origin=i;return t}t.center=v;
/**
     * Create a clone of a model, mirrored on either or both x and y axes.
     *
     * @param modelToMirror The model to mirror.
     * @param mirrorX Boolean to mirror on the x axis.
     * @param mirrorY Boolean to mirror on the y axis.
     * @returns Mirrored model.
     */function d(t,n,r){var a={};if(!t)return null;t.origin&&(a.origin=e.point.mirror(t.origin,n,r));t.type&&(a.type=t.type);"layer"in t&&(a.layer=t.layer);t.units&&(a.units=t.units);if(t.type===e.models.BezierCurve.typeName){a.type=e.models.BezierCurve.typeName;a.seed=e.path.mirror(t.seed,n,r)}if(t.paths){a.paths={};for(var i in t.paths){var o=t.paths[i];if(o){var s=e.path.mirror(o,n,r);s&&(a.paths[i]=s)}}}if(t.models){a.models={};for(var i in t.models){var u=t.models[i];if(u){var l=d(u,n,r);l&&(a.models[i]=l)}}}if(t.caption){a.caption=e.cloneObject(t.caption);a.caption.anchor=e.path.mirror(t.caption.anchor,n,r)}return a}t.mirror=d;
/**
     * Move a model to an absolute point. Note that this is also accomplished by directly setting the origin property. This function exists for cascading.
     *
     * @param modelToMove The model to move.
     * @param origin The new position of the model.
     * @returns The original model (for cascading).
     */function g(t,n){t.origin=e.point.clone(n);return t}t.move=g;
/**
     * Move a model's origin by a relative amount.
     *
     * @param modelToMove The model to move.
     * @param delta The x & y adjustments as a point object.
     * @returns The original model (for cascading).
     */function m(t,n){t&&(t.origin=e.point.add(t.origin||e.point.zero(),n));return t}t.moveRelative=m;
/**
     * Prefix the ids of paths in a model.
     *
     * @param modelToPrefix The model to prefix.
     * @param prefix The prefix to prepend on paths ids.
     * @returns The original model (for cascading).
     */function y(e,t){var n=[];b(e,{onPath:function(e){n.push(e)}});for(var r=0;r<n.length;r++){var a=n[r];delete a.modelContext.paths[a.pathId];a.modelContext.paths[t+a.pathId]=a.pathContext}return e}t.prefixPathIds=y;
/**
     * Rotate a model.
     *
     * @param modelToRotate The model to rotate.
     * @param angleInDegrees The amount of rotation, in degrees.
     * @param rotationOrigin The center point of rotation.
     * @returns The original model (for cascading).
     */function A(t,n,r){r===void 0&&(r=[0,0]);if(!t||!n)return t;var a=e.point.subtract(r,t.origin);t.type===e.models.BezierCurve.typeName&&e.path.rotate(t.seed,n,a);if(t.paths)for(var i in t.paths)e.path.rotate(t.paths[i],n,a);if(t.models)for(var i in t.models)A(t.models[i],n,a);t.caption&&e.path.rotate(t.caption.anchor,n,a);return t}t.rotate=A;
/**
     * Scale a model.
     *
     * @param modelToScale The model to scale.
     * @param scaleValue The amount of scaling.
     * @param scaleOrigin Optional boolean to scale the origin point. Typically false for the root model.
     * @returns The original model (for cascading).
     */function P(t,n,r){r===void 0&&(r=false);r&&t.origin&&(t.origin=e.point.scale(t.origin,n));t.type===e.models.BezierCurve.typeName&&e.path.scale(t.seed,n);if(t.paths)for(var a in t.paths)e.path.scale(t.paths[a],n);if(t.models)for(var a in t.models)P(t.models[a],n,true);t.caption&&e.path.scale(t.caption.anchor,n);return t}t.scale=P;function w(t,n,i,o,s,u,l){var c=e.path.distort(n,s,u);o=o||n.layer;o&&(c.layer=o);if(e.isPath(c))if(c.type===e.pathType.BezierSeed){var p=new e.models.BezierCurve(c,l);a(t,p,i)}else r(t,c,i);else a(t,c,i)}
/**
     * Create a distorted copy of a model - scale x and y individually.
     *
     * @param modelToDistort The model to distort.
     * @param scaleX The amount of x scaling.
     * @param scaleY The amount of y scaling.
     * @param scaleOrigin Optional boolean to scale the origin point. Typically false for the root model.
     * @param bezierAccuracy Optional accuracy of Bezier curves.
     * @returns New model (for cascading).
     */function T(t,n,r,i,o){i===void 0&&(i=false);var s={};t.layer&&(s.layer=t.layer);i&&t.origin&&(s.origin=e.point.distort(t.origin,n,r));if(t.type===e.models.BezierCurve.typeName){var u=t;var l=e.models.BezierCurve.getBezierSeeds(u,{byLayers:true,pointMatchingDistance:o});var c=function(e){var t=l[e];t.forEach((function(t,a){w(s,t,a.toString(),e,n,r,o)}))};for(var p in l)c(p)}else if(t.paths)for(var f in t.paths){var h=t.paths[f];w(s,h,f,null,n,r,o)}if(t.models)for(var v in t.models){var d=t.models[v];var g=T(d,n,r,true,o);a(s,g,v)}if(t.caption){s.caption=e.cloneObject(t.caption);s.caption.anchor=e.path.distort(t.caption.anchor,n,r)}return s}t.distort=T;
/**
     * Convert a model to match a different unit system.
     *
     * @param modeltoConvert The model to convert.
     * @param destUnitType The unit system.
     * @returns The scaled model (for cascading).
     */function x(t,n){if(t.units&&e.units.isValidUnit(t.units)&&e.units.isValidUnit(n)){var r=e.units.conversionScale(t.units,n);if(r!=1){P(t,r);t.units=n}}return t}t.convertUnits=x;
/**
     * DEPRECATED - use model.walk instead.
     * Recursively walk through all paths for a given model.
     *
     * @param modelContext The model to walk.
     * @param callback Callback for each path.
     */function C(e,t){if(e.paths)for(var n in e.paths)e.paths[n]&&t(e,n,e.paths[n]);if(e.models)for(var r in e.models)e.models[r]&&C(e.models[r],t)}t.walkPaths=C;
/**
     * Recursively walk through all child models and paths for a given model.
     *
     * @param modelContext The model to walk.
     * @param options Object containing callbacks.
     * @returns The original model (for cascading).
     */function b(t,n){if(t){r(t,t.layer,[0,0],[],"");return t}function r(t,a,i,o,s){var u=e.point.add(t.origin,i);a=a!=void 0?a:"";if(t.paths)for(var l in t.paths){var c=t.paths[l];if(c){var p={modelContext:t,layer:c.layer!=void 0?c.layer:a,offset:u,pathContext:c,pathId:l,route:o.concat(["paths",l]),routeKey:s+(s?".":"")+"paths"+JSON.stringify([l])};n.onPath&&n.onPath(p)}}if(t.models)for(var f in t.models){var h=t.models[f];if(h){var v={parentModel:t,layer:h.layer!=void 0?h.layer:a,offset:u,route:o.concat(["models",f]),routeKey:s+(s?".":"")+"models"+JSON.stringify([f]),childId:f,childModel:h};if(!n.beforeChildWalk||n.beforeChildWalk(v)){r(v.childModel,v.layer,u,v.route,v.routeKey);n.afterChildWalk&&n.afterChildWalk(v)}}}}}t.walk=b;
/**
     * Move a model so its bounding box begins at [0, 0].
     *
     * @param modelToZero The model to zero.
     * @param zeroX Boolean to zero on the x axis. Default is true.
     * @param zeroY Boolean to zero on the y axis. Default is true.
     * @returns The original model (for cascading).
     */function k(t,n,r){n===void 0&&(n=true);r===void 0&&(r=true);var a=e.measure.modelExtents(t);var i=t.origin||[0,0];n&&(i[0]-=a.low[0]);r&&(i[1]-=a.low[1]);t.origin=i;return t}t.zero=k})(e.model||(e.model={}))})(c||(c={}));(function(e){(function(t){function n(t,n){var r=e.cloneObject(t);if(!r)return null;var a=e.path.breakAtPoint(r,n);if(a){var i=[r,a];for(var o=2;o--;)if(e.round(e.measure.pathLength(i[o]),1e-4)==0)return null;return i}return t.type==e.pathType.Circle?[r]:null}function r(t,n,r){var a=[];t.forEach((function(t){e.measure.isPointOnPath(t,n,1e-5,null,r)&&a.push(t)}));return a}function a(t,a,i){var o=i.pathContext;var s=t.segments;if(e.measure.isPathEqual(s[0].absolutePath,o,1e-4,null,i.offset)){s[0].overlapped=true;s[0].duplicate=true;a.push(s[0])}else{var u={};var l={path1Offset:t.offset,path2Offset:i.offset};var c=e.path.intersection(t.pathContext,o,l);var p=c?c.intersectionPoints:null;var f=e.point.fromPathEnds(o,i.offset)||[];for(var h=0;h<s.length;h++){var v=p?f.concat(p):f;var d=r(v,s[h].absolutePath,u);if(l.out_AreOverlapped){s[h].overlapped=true;a.push(s[h])}if(d.length>0){var g=null;var m=0;while(!g&&m<d.length){g=n(s[h].absolutePath,d[m]);m++}if(g){t.broken=true;s[h].absolutePath=g[0];if(g[1]){var y={absolutePath:g[1],pathId:s[0].pathId,overlapped:s[h].overlapped,uniqueForeignIntersectionPoints:[]};s[h].overlapped&&a.push(y);s.push(y)}h--}}}}}
/**
     * DEPRECATED - use measure.isPointInsideModel instead.
     * Check to see if a path is inside of a model.
     *
     * @param pathContext The path to check.
     * @param modelContext The model to check against.
     * @param farPoint Optional point of reference which is outside the bounds of the modelContext.
     * @returns Boolean true if the path is inside of the modelContext.
     */function i(t,n,r,a,i){var o={farPoint:a,measureAtlas:i};var s=e.point.add(e.point.middle(t),r);return e.measure.isPointInsideModel(s,n,o)}t.isPathInsideModel=i;
/**
     * DEPRECATED
     * Break a model's paths everywhere they intersect with another path.
     *
     * @param modelToBreak The model containing paths to be broken.
     * @param modelToIntersect Optional model containing paths to look for intersection, or else the modelToBreak will be used.
     * @returns The original model (for cascading).
     */function o(t,n){var r=new e.measure.Atlas(t);r.measureModels();var a;if(n){a=new e.measure.Atlas(n);a.measureModels()}else{n=t;a=r}s(t,n||t,false,r,a);return t}t.breakPathsAtIntersections=o;function s(n,r,i,o,s,u){var l=[];var c=[];var p={onPath:function(n){var p={absolutePath:e.path.clone(n.pathContext,n.offset),pathId:n.pathId,overlapped:false,uniqueForeignIntersectionPoints:[]};var f=n;f.broken=false;f.segments=[p];var h={onPath:function(t){n.pathContext!==t.pathContext&&e.measure.isMeasurementOverlapping(o.pathMap[n.routeKey],s.pathMap[t.routeKey])&&a(f,c,t)},beforeChildWalk:function(t){var r=s.modelMap[t.routeKey];return r&&e.measure.isMeasurementOverlapping(o.pathMap[n.routeKey],r)}};t.walk(r,h);if(i)for(var v=0;v<f.segments.length;v++){var d=e.point.middle(f.segments[v].absolutePath);var g={measureAtlas:s,farPoint:u};f.segments[v].isInside=e.measure.isPointInsideModel(d,r,g);f.segments[v].uniqueForeignIntersectionPoints=g.out_intersectionPoints}l.push(f)}};t.walk(n,p);return{crossedPaths:l,overlappedSegments:c}}function u(t,n,r){function a(t,n){e.measure.isPathEqual(t.absolutePath,n.absolutePath,r)&&(t.duplicate=n.duplicate=true)}function i(e){for(var t=0;t<n.length;t++)a(n[t],e)}for(var o=0;o<t.length;o++)i(t[o])}function l(n,r,a,i,o,s){function u(r,a,i){var s=t.getSimilarPathId(r,a);var u=s==a?n.routeKey:e.createRouteKey(n.route.slice(0,-1).concat([s]));i.addedPath=e.cloneObject(n.pathContext);i.addedPath.type=i.absolutePath.type;e.path.copyProps(i.absolutePath,i.addedPath);e.path.moveRelative(i.addedPath,n.offset,true);r.paths[s]=i.addedPath;if(n.broken){var l=e.measure.pathExtents(i.absolutePath);o.pathMap[u]=l;o.modelsMeasured=false}else o.pathMap[u]=c}function l(e,t,i){if(i.isInside&&r||!i.isInside&&a)u(e,t,i);else{o.modelsMeasured=false;s(i.absolutePath,n.routeKey,"segment is "+(i.isInside?"inside":"outside")+" intersectionPoints="+JSON.stringify(i.uniqueForeignIntersectionPoints))}}var c=o.pathMap[n.routeKey];delete n.modelContext.paths[n.pathId];delete o.pathMap[n.routeKey];for(var p=0;p<n.segments.length;p++)n.segments[p].duplicate?i?u(n.modelContext,n.pathId,n.segments[p]):s(n.segments[p].absolutePath,n.routeKey,"segment is duplicate"):l(n.modelContext,n.pathId,n.segments[p])}
/**
     * Combine 2 models. Each model will be modified accordingly.
     *
     * @param modelA First model to combine.
     * @param modelB Second model to combine.
     * @param includeAInsideB Flag to include paths from modelA which are inside of modelB.
     * @param includeAOutsideB Flag to include paths from modelA which are outside of modelB.
     * @param includeBInsideA Flag to include paths from modelB which are inside of modelA.
     * @param includeBOutsideA Flag to include paths from modelB which are outside of modelA.
     * @param options Optional ICombineOptions object.
     * @returns A new model containing both of the input models as "a" and "b".
     */function c(n,r,a,i,o,c,p){a===void 0&&(a=false);i===void 0&&(i=true);o===void 0&&(o=false);c===void 0&&(c=true);var f={trimDeadEnds:true,pointMatchingDistance:.005,out_deleted:[{paths:{}},{paths:{}}]};e.extendObject(f,p);f.measureA=f.measureA||new e.measure.Atlas(n);f.measureB=f.measureB||new e.measure.Atlas(r);f.measureA.measureModels();f.measureB.measureModels();if(!f.farPoint){var h=e.measure.increase(e.measure.increase({high:[null,null],low:[null,null]},f.measureA.modelMap[""]),f.measureB.modelMap[""]);f.farPoint=e.point.add(h.high,[1,1])}var v=s(n,r,true,f.measureA,f.measureB,f.farPoint);var d=s(r,n,true,f.measureB,f.measureA,f.farPoint);u(v.overlappedSegments,d.overlappedSegments,f.pointMatchingDistance);function g(e,n,r,a){t.addPath(f.out_deleted[e],n,"deleted");var i=n;i.reason=a;i.routeKey=r}for(var m=0;m<v.crossedPaths.length;m++)l(v.crossedPaths[m],a,i,true,f.measureA,(function(e,t,n){return g(0,e,t,n)}));for(m=0;m<d.crossedPaths.length;m++)l(d.crossedPaths[m],o,c,false,f.measureB,(function(e,t,n){return g(1,e,t,n)}));var y={models:{a:n,b:r}};if(f.trimDeadEnds){var A;a||o||(A=function(e){for(var t=0;t<v.overlappedSegments.length;t++)if(v.overlappedSegments[t].duplicate&&e.pathContext===v.overlappedSegments[t].addedPath)return false;return true});t.removeDeadEnds(y,null,A,(function(e,t){var n=e.route[1]==="a"?0:1;g(n,e.pathContext,e.routeKey,t)}))}e.extendObject(p,f);return y}t.combine=c;
/**
     * Combine 2 models, resulting in a intersection. Each model will be modified accordingly.
     *
     * @param modelA First model to combine.
     * @param modelB Second model to combine.
     * @returns A new model containing both of the input models as "a" and "b".
     */function p(e,t){return c(e,t,true,false,true,false)}t.combineIntersection=p;
/**
     * Combine 2 models, resulting in a subtraction of B from A. Each model will be modified accordingly.
     *
     * @param modelA First model to combine.
     * @param modelB Second model to combine.
     * @returns A new model containing both of the input models as "a" and "b".
     */function f(e,t){return c(e,t,false,true,true,false)}t.combineSubtraction=f;
/**
     * Combine 2 models, resulting in a union. Each model will be modified accordingly.
     *
     * @param modelA First model to combine.
     * @param modelB Second model to combine.
     * @returns A new model containing both of the input models as "a" and "b".
     */function h(e,t){return c(e,t,false,true,false,true)}t.combineUnion=h})(e.model||(e.model={}))})(c||(c={}));(function(e){var t=function(){function e(e){(this||u).comparer=e;(this||u).collections=[]}e.prototype.addItemToCollection=function(e,t){var n=this.findCollection(e);if(n)n.push(t);else{var r={key:e,items:[t]};(this||u).collections.push(r)}};e.prototype.findCollection=function(e,t){for(var n=0;n<(this||u).collections.length;n++){var r=(this||u).collections[n];if(this.comparer(e,r.key)){t&&t(n);return r.items}}return null};e.prototype.removeCollection=function(e){var t=this||u;return!!this.findCollection(e,(function(e){t.collections.splice(e,1)}))};e.prototype.removeItemFromCollection=function(e,t){var n=this.findCollection(e);if(n){for(var r=0;r<n.length;r++)if(n[r]===t){n.splice(r,1);return true}return false}};e.prototype.getCollectionsOfMultiple=function(e){for(var t=0;t<(this||u).collections.length;t++){var n=(this||u).collections[t];n.items.length>1&&e(n.key,n.items)}};return e}();e.Collector=t;var n=i;var r=n.default||n;var a=function(){function t(){this.reset()}t.prototype.reset=function(){(this||u).insertedCount=0;(this||u).graph={};(this||u).index={};(this||u).merged={};(this||u).values=[]};
/**
     * Insert a value.
     * @param value Value associated with this point.
     * @returns valueId of the inserted value.
     */t.prototype.insertValue=function(e){(this||u).values.push(e);return(this||u).values.length-1};
/**
     * Insert a value at a point.
     * @param p Point.
     * @param value Value associated with this point.
     */t.prototype.insertValueIdAtPoint=function(e,t){var n=t[0],r=t[1];(this||u).graph[n]||((this||u).graph[n]={});var a=(this||u).graph[n];var i=r in a;var o;var s;if(i){s=a[r];s in(this||u).merged&&(s=(this||u).merged[s]);o=(this||u).index[s];o.valueIds.push(e)}else{a[r]=s=(this||u).insertedCount++;o={pointId:s,point:t,valueIds:[e]};(this||u).index[s]=o}return{existed:i,pointId:s}};
/**
     * Merge points within a given distance from each other. Call this after inserting values.
     * @param withinDistance Distance to consider points equal.
     */t.prototype.mergePoints=function(e){var t=this||u;var n=[];var a=[];for(var i in(this||u).index){var o=(this||u).index[i];var s=o.point;o.kdId=n.length;n.push(s);a.push(o)}(this||u).kdbush=r(n);var l=function(n){if(n in c.merged)return"continue";var r=c.index[n];var i=c.kdbush.within(r.point[0],r.point[1],e);i.forEach((function(e){e!==r.kdId&&t.mergeIndexElements(r,a[e])}))};var c=this||u;for(var i in(this||u).index)l(i)};
/**
     * Finds all points which have only one value associated. Then, merge to the nearest other point within this set.
     * Call this after inserting values.
     * @param withinDistance Distance to consider points equal.
     */t.prototype.mergeNearestSinglePoints=function(t){var n=this||u;var a=[];for(var i in(this||u).index){var o=(this||u).index[i];o.valueIds.length===1&&a.push(o)}(this||u).kdbush=r(a.map((function(e){return e.point})));a.forEach((function(r){if(!(r.pointId in n.merged)){var i=n.kdbush.within(r.point[0],r.point[1],t);var o=[];i.forEach((function(t){var n=a[t];n.pointId!==r.pointId&&o.push({el:n,distance:e.measure.pointDistance(n.point,r.point)})}));o.sort((function(e,t){return e.distance-t.distance}));for(var s=0;s<o.length;s++){var u=o[s].el;if(!(u.pointId in n.merged)){u.merged&&u.merged.length>0?n.mergeIndexElements(u,r):n.mergeIndexElements(r,u);return}}}}))};t.prototype.mergeIndexElements=function(e,t){e.merged=e.merged||[];e.merged.push(t.pointId);(this||u).merged[t.pointId]=e.pointId;e.valueIds.push.apply(e.valueIds,t.valueIds);delete(this||u).index[t.pointId];return e.pointId};
/**
     * Iterate over points in the index.
     * @param cb Callback for each point in the index.
     */t.prototype.forEachPoint=function(e){var t=this||u;for(var n=0;n<(this||u).insertedCount;n++){var r=(this||u).index[n];if(r){var a=r.valueIds.length;a>0&&e(r.point,r.valueIds.map((function(e){return t.values[e]})),n,r)}}};
/**
     * Gets the id of a point, after merging.
     * @param p Point to look up id.
     */t.prototype.getIdOfPoint=function(e){var t=(this||u).graph[e[0]];if(t){var n=t[e[1]];if(n>=0)return n in(this||u).merged?(this||u).merged[n]:n}};
/**
     * Get the index element of a point, after merging.
     * @param p Point to look up index element.
     */t.prototype.getElementAtPoint=function(e){var t=this.getIdOfPoint(e);if(t>=0)return(this||u).index[t]};return t}();e.PointGraph=a})(c||(c={}));(function(e){(function(t){function n(e,t,n){var r=0;do{var a=e[r];do{var i=false;for(var o=r+1;o<e.length;o++){var s=e[o];i=t(a.pathContext,s.pathContext,false);if(i){n(a.pathContext,s.pathContext);delete s.modelContext.paths[s.pathId];e.splice(o,1);break}}}while(i);r++}while(r<e.length)}
/**
     * Simplify a model's paths by reducing redundancy: combine multiple overlapping paths into a single path. The model must be originated.
     *
     * @param modelContext The originated model to search for similar paths.
     * @param options Optional options object.
     * @returns The simplified model (for cascading).
     */function r(r,a){function i(t,n){if(Math.abs(t.radius-n.radius)<=c.scalarMatchingDistance){var r=e.measure.pointDistance(t.origin,n.origin);return r<=c.pointMatchingDistance}return false}var o=new e.Collector(i);var s=new e.Collector(i);var u=new e.Collector(e.measure.isSlopeEqual);var l={};l[e.pathType.Arc]=function(e){o.addItemToCollection(e.pathContext,e)};l[e.pathType.Circle]=function(e){s.addItemToCollection(e.pathContext,e)};l[e.pathType.Line]=function(t){var n=e.measure.lineSlope(t.pathContext);u.addItemToCollection(n,t)};var c={scalarMatchingDistance:.001,pointMatchingDistance:.005};e.extendObject(c,a);var p={onPath:function(e){var t=l[e.pathContext.type];t&&t(e)}};t.walk(r,p);o.getCollectionsOfMultiple((function(t,r){n(r,e.measure.isArcOverlapping,(function(t,n){var r=e.measure.isBetweenArcAngles(t.endAngle,n,false);var a=e.measure.isBetweenArcAngles(n.endAngle,t,false);if(r&&a)t.endAngle=t.startAngle+360;else{var i=r?[t,n]:[n,t];t.startAngle=e.angle.noRevolutions(i[0].startAngle);t.endAngle=i[1].endAngle}}))}));s.getCollectionsOfMultiple((function(e,t){for(var n=1;n<t.length;n++){var r=t[n];delete r.modelContext.paths[r.pathId]}}));u.getCollectionsOfMultiple((function(t,r){n(r,e.measure.isLineOverlapping,(function(n,r){var a={paths:{lineA:n,lineB:r}};var i=e.measure.modelExtents(a);if(t.hasSlope)if(t.slope<0){n.origin=[i.low[0],i.high[1]];n.end=[i.high[0],i.low[1]]}else if(t.slope>0){n.origin=i.low;n.end=i.high}else{n.origin[0]=i.low[0];n.end[0]=i.high[0]}else{n.origin[1]=i.low[1];n.end[1]=i.high[1]}}))}));return r}t.simplify=r})(e.model||(e.model={}))})(c||(c={}));(function(e){(function(t){var n={};n[e.pathType.Arc]=function(t,n,r){return new e.models.OvalArc(t.startAngle,t.endAngle,t.radius,n,false,r)};n[e.pathType.Circle]=function(t,n,r){return new e.models.Ring(t.radius+n,t.radius-n)};n[e.pathType.Line]=function(t,n,r){return new e.models.Slot(t.origin,t.end,n,r)};
/**
     * Expand path by creating a model which surrounds it.
     *
     * @param pathToExpand Path to expand.
     * @param expansion Distance to expand.
     * @param isolateCaps Optional flag to put the end caps into a separate model named "caps".
     * @returns Model which surrounds the path.
     */function r(e,t,r){if(!e)return null;var a=null;var i=n[e.type];if(i){a=i(e,t,r);a.origin=e.origin}return a}t.expand=r;
/**
     * Represent an arc using straight lines.
     *
     * @param arc Arc to straighten.
     * @param bevel Optional flag to bevel the angle to prevent it from being too sharp.
     * @param prefix Optional string prefix to apply to path ids.
     * @param close Optional flag to make a closed geometry by connecting the endpoints.
     * @returns Model of straight lines with same endpoints as the arc.
     */function a(t,n,r,a){var i=e.angle.ofArcSpan(t);var o=1;i>=270?o=4:i>180?o=3:(i>150||n)&&(o=2);var s=e.angle.toRadians(i/o);var u=e.models.Polygon.circumscribedRadius(t.radius,s);var l=e.point.fromArc(t);var c=[e.point.subtract(l[0],t.origin)];var p=e.angle.toRadians(t.startAngle)+s/2;for(var f=0;f<o;f++){c.push(e.point.fromPolar(p,u));p+=s}c.push(e.point.subtract(l[1],t.origin));var h=new e.models.ConnectTheDots(a,c);h.origin=t.origin;typeof r==="string"&&r.length&&e.model.prefixPathIds(h,r);return h}t.straighten=a})(e.path||(e.path={}))})(c||(c={}));(function(e){(function(t){
/**
     * Expand all paths in a model, then combine the resulting expansions.
     *
     * @param modelToExpand Model to expand.
     * @param distance Distance to expand.
     * @param joints Number of points at a joint between paths. Use 0 for round joints, 1 for pointed joints, 2 for beveled joints.
     * @param combineOptions Optional object containing combine options.
     * @returns Model which surrounds the paths of the original model.
     */
function n(n,r,a,i){a===void 0&&(a=0);i===void 0&&(i={});if(r<=0)return null;var o={models:{expansions:{models:{}},caps:{models:{}}}};var s=true;var u=i.farPoint;var l={onPath:function(n){if(!(i.pointMatchingDistance&&e.measure.pathLength(n.pathContext)<i.pointMatchingDistance)){var a=e.path.expand(n.pathContext,r,true);if(a){t.moveRelative(a,n.offset);var l=t.getSimilarModelId(o.models.expansions,n.pathId);t.prefixPathIds(a,n.pathId+"_");t.originate(a);if(!s){t.combine(o,a,false,true,false,true,i);i.measureA.modelsMeasured=false;u=i.farPoint;delete i.farPoint;delete i.measureB}o.models.expansions.models[l]=a;if(a.models){var c=a.models.Caps;if(c){delete a.models.Caps;o.models.caps.models[l]=c}}s=false}}}};t.walk(n,l);if(a){var c=o.models.caps;var p={models:{}};o.models.straightcaps=p;t.simplify(c);for(var f in c.models){p.models[f]={models:{}};t.walk(c.models[f],{onPath:function(n){var r=n.pathContext;var s=e.path.straighten(r,a==2,n.pathId+"_",true);t.combine(o,s,false,true,false,true,i);i.measureA.modelsMeasured=false;u=i.farPoint;delete i.farPoint;delete i.measureB;p.models[f].models[n.pathId]=s;delete n.modelContext.paths[n.pathId]}})}delete o.models.caps}i.farPoint=u;return o}t.expandPaths=n;function r(e){var n=[];t.findChains(e,(function(e,t,r){n=e.filter((function(e){return e.endless}))}));return n}function a(t){var n=r(t);if(n.length==0)return null;var a={models:{}};n.forEach((function(t,n){a.models[n]=e.chain.toNewModel(t)}));return a}
/**
     * Outline a model by a specified distance. Useful for accommodating for kerf.
     *
     * @param modelToOutline Model to outline.
     * @param distance Distance to outline.
     * @param joints Number of points at a joint between paths. Use 0 for round joints, 1 for pointed joints, 2 for beveled joints.
     * @param inside Optional boolean to draw lines inside the model instead of outside.
     * @param options Options to send to combine() function.
     * @returns Model which surrounds the paths outside of the original model.
     */function i(t,i,o,s,u){o===void 0&&(o=0);s===void 0&&(s=false);u===void 0&&(u={});var l=n(t,i,o,u);if(!l)return null;var c=a(t);if(c){var p=0;var f={models:{}};var h=r(l);h.forEach((function(t){var n=t.links[0].walkedPath;var r=e.measure.isPointInsideModel(e.point.middle(n.pathContext),c,n.offset);(s&&r||!s&&!r)&&(f.models[p++]=e.chain.toNewModel(t))}));return f}return l}t.outline=i})(e.model||(e.model={}))})(c||(c={}));(function(e){(function(t){var n=e.unitType.Millimeter;function r(){o(e.unitType.Centimeter,10);o(e.unitType.Meter,1e3);o(e.unitType.Inch,25.4);o(e.unitType.Foot,25.4*12)}var a;function i(e,t,n){function r(e){a[e]||(a[e]={});return a[e]}r(e)[t]=n;r(t)[e]=1/n}function o(e,t){i(e,n,t)}
/**
     * Get a conversion ratio between a source unit and a destination unit.
     *
     * @param srcUnitType unitType converting from.
     * @param destUnitType unitType converting to.
     * @returns Numeric ratio of the conversion.
     */function s(e,t){if(e==t)return 1;if(!a){a={};r()}a[e][t]||i(e,t,a[e][n]*a[n][t]);return a[e]&&a[e][t]}t.conversionScale=s;
/**
     * Check to see if unit type is a valid Maker.js unit.
     *
     * @param tryUnit unit type to check.
     * @returns Boolean true if unit type is valid.
     */function u(t){for(var n in e.unitType)if(e.unitType[n]==t)return true;return false}t.isValidUnit=u})(e.units||(e.units={}))})(c||(c={}));(function(e){(function(t){
/**
     * Find out if two angles are equal.
     *
     * @param angleA First angle.
     * @param angleB Second angle.
     * @returns true if angles are the same, false if they are not
     */
function n(t,n,r){r===void 0&&(r=1e-4);var a=e.angle.noRevolutions(t);var i=e.angle.noRevolutions(n);var o=e.angle.noRevolutions(e.round(i-a,r));return o==0}t.isAngleEqual=n;var r={};r[e.pathType.Line]=function(e,t,n){return i(e.origin,t.origin,n)&&i(e.end,t.end,n)||i(e.origin,t.end,n)&&i(e.end,t.origin,n)};r[e.pathType.Circle]=function(e,t,n){return i(e.origin,t.origin,n)&&e.radius==t.radius};r[e.pathType.Arc]=function(t,a,i){return r[e.pathType.Circle](t,a,i)&&n(t.startAngle,a.startAngle)&&n(t.endAngle,a.endAngle)};
/**
     * Find out if two paths are equal.
     *
     * @param pathA First path.
     * @param pathB Second path.
     * @returns true if paths are the same, false if they are not
     */function a(t,n,a,i,o){var s=false;if(t.type==n.type){var u=r[t.type];if(u){function l(){s=u(t,n,a)}i||o?e.path.moveTemporary([t,n],[i,o],l):l()}}return s}t.isPathEqual=a;
/**
     * Find out if two points are equal.
     *
     * @param a First point.
     * @param b Second point.
     * @param withinDistance Optional distance to consider points equal.
     * @returns true if points are the same, false if they are not
     */function i(n,r,a){if(a){if(!n||!r)return false;var i=t.pointDistance(n,r);return i<=a}return e.round(n[0]-r[0])==0&&e.round(n[1]-r[1])==0}t.isPointEqual=i;
/**
     * Find out if a point is distinct among an array of points.
     *
     * @param pointToCheck point to check.
     * @param pointArray array of points.
     * @param withinDistance Optional distance to consider points equal.
     * @returns false if point is equal to any point in the array.
     */function o(e,t,n){for(var r=0;r<t.length;r++)if(i(t[r],e,n))return false;return true}t.isPointDistinct=o;
/**
     * Find out if point is on a slope.
     *
     * @param p Point to check.
     * @param b Slope.
     * @param withinDistance Optional distance of tolerance.
     * @returns true if point is on the slope
     */function s(e,t,n){n===void 0&&(n=0);return t.hasSlope?Math.abs(e[1]-(t.slope*e[0]+t.yIntercept))<=n:Math.abs(e[0]-t.line.origin[0])<=n}t.isPointOnSlope=s;
/**
     * Find out if point is on a circle.
     *
     * @param p Point to check.
     * @param circle Circle.
     * @param withinDistance Optional distance of tolerance.
     * @returns true if point is on the circle
     */function u(e,n,r){r===void 0&&(r=0);var a=Math.abs(t.pointDistance(e,n.origin)-n.radius);return a<=r}t.isPointOnCircle=u;var l={};l[e.pathType.Circle]=function(e,t,n){return u(e,t,n)};l[e.pathType.Arc]=function(n,r,a){if(l[e.pathType.Circle](n,r,a)){var i=e.angle.ofPointInDegrees(r.origin,n);return t.isBetweenArcAngles(i,r,false)}return false};l[e.pathType.Line]=function(e,n,r,a){var i=a&&a.cachedLineSlope||t.lineSlope(n);a&&!a.cachedLineSlope&&(a.cachedLineSlope=i);return s(e,i,r)&&t.isBetweenPoints(e,n,false)};
/**
     * Find out if a point lies on a path.
     * @param pointToCheck point to check.
     * @param onPath path to check against.
     * @param withinDistance Optional distance to consider point on the path.
     * @param pathOffset Optional offset of path from [0, 0].
     * @param options Optional IIsPointOnPathOptions to cache computation.
     */function c(t,n,r,a,i){r===void 0&&(r=0);var o=l[n.type];if(o){var s=a?e.path.clone(n,a):n;return o(t,s,r,i)}return false}t.isPointOnPath=c;
/**
     * Check for slope equality.
     *
     * @param slopeA The ISlope to test.
     * @param slopeB The ISlope to check for equality.
     * @returns Boolean true if slopes are equal.
     */function p(t,n){if(!f(t,n))return false;if(!t.hasSlope&&!n.hasSlope)return e.round(t.line.origin[0]-n.line.origin[0])==0;var r=[t,n];var a=r.map((function(t){return e.angle.toDegrees(Math.atan(t.slope))}));var i=r.map((function(t){return e.path.clone(t.line)}));var o=i[0].origin;i.forEach((function(t,n){return e.path.rotate(t,-a[n],o)}));var s=i.map((function(e){return(e.origin[1]+e.end[1])/2}));return e.round(s[0]-s[1],1e-5)==0}t.isSlopeEqual=p;
/**
     * Check for parallel slopes.
     *
     * @param slopeA The ISlope to test.
     * @param slopeB The ISlope to check for parallel.
     * @returns Boolean true if slopes are parallel.
     */function f(t,n){return!t.hasSlope&&!n.hasSlope||!(!t.hasSlope||!n.hasSlope||e.round(t.slope-n.slope,1e-5)!=0)}t.isSlopeParallel=f})(e.measure||(e.measure={}))})(c||(c={}));(function(e){(function(t){
/**
     * Increase a measurement by an additional measurement.
     *
     * @param baseMeasure The measurement to increase.
     * @param addMeasure The additional measurement.
     * @param augmentBaseMeasure Optional flag to call measure.augment on the measurement.
     * @returns The increased original measurement (for cascading).
     */
function n(e,t,n){function r(e,t,n){if(t)for(var r=2;r--;)t[r]!=null&&(e[r]==null?e[r]=t[r]:e[r]=n(e[r],t[r]))}if(t){r(e.low,t.low,Math.min);r(e.high,t.high,Math.max)}n&&M(e);return e}t.increase=n;
/**
     * Check for arc being concave or convex towards a given point.
     *
     * @param arc The arc to test.
     * @param towardsPoint The point to test.
     * @returns Boolean true if arc is concave towards point.
     */function r(t,n){if(A(t.origin,n)<=t.radius)return true;var r=new e.paths.Line(e.point.middle(t),n);var a={};var i=e.path.intersection(r,new e.paths.Chord(t),a);return!(!i&&!a.out_AreOverlapped)}t.isArcConcaveTowardsPoint=r;function a(e,t,n){return i(e,t,n)}t.isArcOverlapping=a;
/**
     * Check for arc overlapping another arc.
     *
     * @param arcA The arc to test.
     * @param arcB The arc to check for overlap.
     * @param excludeTangents Boolean to exclude exact endpoints and only look for deep overlaps.
     * @returns Boolean true if arcA is overlapped with arcB.
     */function i(e,t,n){function r(e,t){function r(t){return l(t,e,n)}return r(t.startAngle)||r(t.endAngle)}return r(e,t)||r(t,e)||e.startAngle==t.startAngle&&e.endAngle==t.endAngle}t.isArcSpanOverlapping=i;
/**
     * Check if a given number is between two given limits.
     *
     * @param valueInQuestion The number to test.
     * @param limitA First limit.
     * @param limitB Second limit.
     * @param exclusive Flag to exclude equaling the limits.
     * @returns Boolean true if value is between (or equal to) the limits.
     */function s(e,t,n,r){return r?Math.min(t,n)<e&&e<Math.max(t,n):Math.min(t,n)<=e&&e<=Math.max(t,n)}t.isBetween=s;
/**
     * Check if a given angle is between an arc's start and end angles.
     *
     * @param angleInQuestion The angle to test.
     * @param arc Arc to test against.
     * @param exclusive Flag to exclude equaling the start or end angles.
     * @returns Boolean true if angle is between (or equal to) the arc's start and end angles.
     */function l(t,n,r){var a=e.angle.noRevolutions(n.startAngle);var i=e.angle.ofArcSpan(n);var o=a+i;t=e.angle.noRevolutions(t);return s(t,a,o,r)||s(t,a+360,o+360,r)||s(t,a-360,o-360,r)}t.isBetweenArcAngles=l;
/**
     * Check if a given point is between a line's end points.
     *
     * @param pointInQuestion The point to test.
     * @param line Line to test against.
     * @param exclusive Flag to exclude equaling the origin or end points.
     * @returns Boolean true if point is between (or equal to) the line's origin and end points.
     */function c(t,n,r){var a=false;for(var i=2;i--;)if(e.round(n.origin[i]-n.end[i],1e-6)!=0){var o=e.round(n.origin[i]);var u=e.round(n.end[i]);if(!s(e.round(t[i]),o,u,r))return false}else{if(a)return false;a=true}return true}t.isBetweenPoints=c;
/**
     * Check if a given bezier seed has all points on the same slope.
     *
     * @param seed The bezier seed to test.
     * @param exclusive Optional boolean to test only within the boundary of the endpoints.
     * @returns Boolean true if bezier seed has control points on the line slope and between the line endpoints.
     */function p(e,n){var r=y(e);for(var a=0;a<e.controls.length;a++)if(!t.isPointOnSlope(e.controls[a],r)){if(!n)return false;if(c(e.controls[a],e,false))return false}return true}t.isBezierSeedLinear=p;var f=o;function h(e){return e.join(",")}
/**
     * Check for flow of paths in a chain being clockwise or not.
     *
     * @param chainContext The chain to test.
     * @param out_result Optional output object, if provided, will be populated with convex hull results.
     * @returns Boolean true if paths in the chain flow clockwise.
     */function v(t,n){if(!t.endless||t.links.length===1)return null;var r=e.chain.toKeyPoints(t);return d(r,n)}t.isChainClockwise=v;
/**
     * Check for array of points being clockwise or not.
     *
     * @param points The array of points to test.
     * @param out_result Optional output object, if provided, will be populated with convex hull results.
     * @returns Boolean true if points flow clockwise.
     */function d(e,t){var n=new f;var r=[];function a(e){n.addPoint(e[0],e[1]);r.push(h(e))}e.forEach(a);var i=n.getHull();var o=i.slice(0,3).map((function(e){return h([e.x,e.y])}));var s=[];r.forEach((function(e){~o.indexOf(e)&&s.push(e)}));switch(s.indexOf(o[1])){case 0:s.unshift(s.pop());break;case 2:s.push(s.shift());break}if(t){t.hullPoints=i.map((function(e){return[e.x,e.y]}));t.keyPoints=e}return o[0]!=s[0]}t.isPointArrayClockwise=d;
/**
     * Check for line overlapping another line.
     *
     * @param lineA The line to test.
     * @param lineB The line to check for overlap.
     * @param excludeTangents Boolean to exclude exact endpoints and only look for deep overlaps.
     * @returns Boolean true if lineA is overlapped with lineB.
     */function g(e,t,n){function r(e,t,r){function a(e){return c(e,t,n)}return a(r.origin)||a(r.end)}return r(0,e,t)||r(1,t,e)}t.isLineOverlapping=g;
/**
     * Check for measurement overlapping another measurement.
     *
     * @param measureA The measurement to test.
     * @param measureB The measurement to check for overlap.
     * @returns Boolean true if measureA is overlapped with measureB.
     */function m(t,n){for(var r=2;r--;)if(!(e.round(t.low[r]-n.high[r])<=0&&e.round(t.high[r]-n.low[r])>=0))return false;return true}t.isMeasurementOverlapping=m;function y(t){var n=t.end[0]-t.origin[0];if(e.round(n,1e-6)==0)return{line:t,hasSlope:false};var r=t.end[1]-t.origin[1];var a=r/n;var i=t.origin[1]-a*t.origin[0];return{line:t,hasSlope:true,slope:a,yIntercept:i}}t.lineSlope=y;
/**
     * Calculates the distance between two points.
     *
     * @param a First point.
     * @param b Second point.
     * @returns Distance between points.
     */function A(e,t){var n=t[0]-e[0];var r=t[1]-e[1];return Math.sqrt(n*n+r*r)}t.pointDistance=A;function P(e,t,n){return[n(e[0],t[0]),n(e[1],t[1])]}var w={};w[e.pathType.Line]=function(e){return{low:P(e.origin,e.end,Math.min),high:P(e.origin,e.end,Math.max)}};w[e.pathType.Circle]=function(t){var n=t.radius;return{low:e.point.add(t.origin,[-n,-n]),high:e.point.add(t.origin,[n,n])}};w[e.pathType.Arc]=function(t){var n=t.radius;var r=e.point.fromArc(t);function a(e,n,a){var i=P(r[0],r[1],a);for(var o=2;o--;)l(e[o],t,false)&&(i[o]=n+t.origin[o]);return i}return{low:a([180,270],-n,Math.min),high:a([360,90],n,Math.max)}};
/**
     * Calculates the smallest rectangle which contains a path.
     *
     * @param pathToMeasure The path to measure.
     * @returns object with low and high points.
     */function T(t,n){if(t){var r=w[t.type];if(r){var a=r(t);if(n){a.high=e.point.add(a.high,n);a.low=e.point.add(a.low,n)}return a}}return{low:null,high:null}}t.pathExtents=T;var x={};x[e.pathType.Line]=function(e){return A(e.origin,e.end)};x[e.pathType.Circle]=function(e){return 2*Math.PI*e.radius};x[e.pathType.Arc]=function(t){var n=x[e.pathType.Circle](t);var r=e.angle.ofArcSpan(t)/360;n*=r;return n};x[e.pathType.BezierSeed]=function(t){return e.models.BezierCurve.computeLength(t)};
/**
     * Measures the length of a path.
     *
     * @param pathToMeasure The path to measure.
     * @returns Length of the path.
     */function C(e){if(e){var t=x[e.type];if(t)return t(e)}return 0}t.pathLength=C;
/**
     * Measures the length of all paths in a model.
     *
     * @param modelToMeasure The model containing paths to measure.
     * @returns Length of all paths in the model.
     */function b(t){var n=0;e.model.walk(t,{onPath:function(e){n+=C(e.pathContext)}});return n}t.modelPathLength=b;function k(t){return{high:e.point.clone(t.high),low:e.point.clone(t.low)}}
/**
     * Measures the smallest rectangle which contains a model.
     *
     * @param modelToMeasure The model to measure.
     * @param atlas Optional atlas to save measurements.
     * @returns object with low and high points.
     */function L(t,r){function a(t,a){if(a){var i=t.slice(0,-2);var o=e.createRouteKey(i);o in r.modelMap?n(r.modelMap[o],a):r.modelMap[o]=k(a)}}r||(r=new I(t));var i={onPath:function(e){e.routeKey in r.pathMap||(r.pathMap[e.routeKey]=T(e.pathContext,e.offset));a(e.route,r.pathMap[e.routeKey])},afterChildWalk:function(e){a(e.route,r.modelMap[e.routeKey])}};e.model.walk(t,i);r.modelsMeasured=true;var o=r.modelMap[""];return o?M(o):null}t.modelExtents=L;
/**
     * Augment a measurement - add more properties such as center point, height and width.
     *
     * @param measureToAugment The measurement to augment.
     * @returns Measurement object with augmented properties.
     */function M(t){var n=t;n.center=e.point.average(n.high,n.low);n.width=n.high[0]-n.low[0];n.height=n.high[1]-n.low[1];return n}t.augment=M;
/**
     * A list of maps of measurements.
     *
     * @param modelToMeasure The model to measure.
     * @param atlas Optional atlas to save measurements.
     * @returns object with low and high points.
     */var I=function(){
/**
       * Constructor.
       * @param modelContext The model to measure.
       */
function e(e){(this||u).modelContext=e;(this||u).modelsMeasured=false;(this||u).modelMap={};(this||u).pathMap={}}e.prototype.measureModels=function(){(this||u).modelsMeasured||L((this||u).modelContext,this||u)};return e}();t.Atlas=I;function S(e,t){return t>=e?t-e:t<0?t+e:t}function E(e,t){return e.slope*t+e.yIntercept}function O(e,t){var n=y(e);return[t,E(n,t)]}function D(n){for(var r=1;r<3;r++)if(!t.isPointEqual(n[0].center,n[r].center,1e-6)||!(e.round(n[0].width-n[r].width)===0))return false;return true}function z(t,n,r,a){e.model.rotate(n,r);var i=L(n);var o={index:t,rotation:a,center:e.point.rotate(i.center,a),width:i.height,height:i.width,bottom:new e.paths.Line(i.low,[i.high[0],i.low[1]]),middle:new e.paths.Line([i.low[0],i.center[1]],[i.high[0],i.center[1]]),top:new e.paths.Line(i.high,[i.low[0],i.high[1]])};[o.top,o.middle,o.bottom].forEach((function(t){return e.path.rotate(t,a)}));return o}function R(t,n){var r=t[1].origin;var a=r[0];var i=t[3].origin[0];var o=t[0].origin[0];var s=a-o;if(o-i>2*s)return null;var u=(a-i)/3;if(s<u)return null;var l=Math.min(u,s);var c=e.solvers.equilateralSide(l);var p=[e.point.fromSlopeIntersection(t[1],t[2]),e.point.fromSlopeIntersection(t[4],t[5])];var f=p.map((function(e){return Math.abs(e[1]-r[1])}));var h=f[0]>f[1]?0:1;var v=f[h];if(v>c){var d=e.solvers.equilateralAltitude(v);var g=a-2*d;if(o>g+d)return null;if(i<g-d)return null;var m=i-g+d;var y=2*d-n[h+1].width;var A=Math.min(m,y)/2;return{origin:O(n[2-h].middle,g+A),radius:v,type:"peak "+h}}return{origin:[a-2*l,r[1]],radius:c,type:"side"}}
/**
     * Measures the minimum bounding hexagon surrounding a model. The hexagon is oriented such that the right and left sides are vertical, and the top and bottom are pointed.
     *
     * @param modelToMeasure The model to measure.
     * @returns IBoundingHex object which is a hexagon model, with an additional radius property.
     */function B(t){var n=e.cloneObject(t);e.model.originate(n);var r=L(n);var a=[];var i={paths:{}};e.model.center(n);function o(t,n,a){return{radius:t,paths:new e.models.Polygon(6,t,30).paths,origin:e.point.add(n,r.center),notes:a}}var s=[[90,-90],[-60,-30],[-60,30]];while(s.length){var u=s.shift();var l=z(a.length,n,u[0],u[1]);var c=e.solvers.equilateralSide(l.width/2);if(c>=l.height)return o(c,l.center,"solved by bound "+a.length);a.push(l)}if(D(a))return o(e.solvers.equilateralSide(a[0].width/2),a[0].center,"solved as circular");var p=a.map((function(e){return e.top})).concat(a.map((function(e){return e.bottom})));p.forEach((function(t,n){i.paths[n]=t;e.path.converge(p[S(6,n+2)],t,true)}));a.forEach((function(e,t){i.paths["m"+t]=e.middle}));var f=a.slice();var h;for(var v=0;v<6;v++){if(v>0){p.push(p.shift());f.push(f.shift());e.model.rotate(i,-60)}var d=R(p,f);if(d&&(!h||d.radius<h.radius)){h=d;h.index=v}}var g=e.point.rotate(h.origin,h.index*60);return o(h.radius,g,"solved by "+h.index+" as "+h.type)}t.boundingHexagon=B;function N(e,n){var r=0;n.forEach((function(n){if(t.isPointDistinct(n,e,1e-8)){e.push(n);r++}}));return r}function j(t,n,r){if(n)return n;var a=L(t).high;return a?e.point.add(a,[1,1]):[7654321,1234567]}
/**
     * Check to see if a point is inside of a model.
     *
     * @param pointToCheck The point to check.
     * @param modelContext The model to check against.
     * @param options Optional IMeasurePointInsideOptions object.
     * @returns Boolean true if the path is inside of the modelContext.
     */function _(t,n,r){r===void 0&&(r={});r.farPoint||(r.farPoint=j(n,r.farPoint,r.measureAtlas));r.out_intersectionPoints=[];var a;var i=new e.paths.Line(t,r.farPoint);var o=T(i);var s={onPath:function(t){if(!r.measureAtlas||m(o,r.measureAtlas.pathMap[t.routeKey])){var n={path2Offset:t.offset};var s=e.path.intersection(i,t.pathContext,n);if(s){var u=N(r.out_intersectionPoints,s.intersectionPoints);u%2==1&&(a=!!!a)}}},beforeChildWalk:function(e){if(!r.measureAtlas)return true;var t=r.measureAtlas.modelMap[e.routeKey];return t&&m(o,t)}};e.model.walk(n,s);return!!a}t.isPointInsideModel=_})(e.measure||(e.measure={}))})(c||(c={}));(function(e){(function(t){
/**
     * Renders an item in JSON.
     *
     * @param itemToExport Item to render: may be a path, an array of paths, or a model object.
     * @param options Rendering options object.
     * @param options.accuracy Optional exemplar of number of decimal places.
     * @param options.indentation Optional number of characters to indent after a newline.
     * @returns String of DXF content.
     */
function n(t,n){n===void 0&&(n={});function r(t,r){if(e.isNumber(r)){var a=e.round(r,n.accuracy);return a}if(e.isPoint(r)){var i=e.point.rounded(r,n.accuracy);return i}return r}return JSON.stringify(t,n.accuracy&&r,n.indentation)}t.toJson=n;function r(t){if(e.isModel(t))return t.units}t.tryGetModelUnits=r;t.colors={black:0,red:1,yellow:2,lime:3,aqua:4,blue:5,fuchsia:6,white:7,gray:9,maroon:14,orange:30,olive:58,green:94,teal:134,navy:174,purple:214,silver:254}})(e.exporter||(e.exporter={}))})(c||(c={}));(function(e){(function(e){
/**
     * Create a numeric array from a string of numbers. The numbers may be delimited by anything non-numeric.
     *
     * Example:
     * ```
     * var n = makerjs.importer.parseNumericList('5, 10, 15.20 25-30-35 4e1 .5');
     * ```
     *
     * @param s The string of numbers.
     * @returns Array of numbers.
     */
function t(e){var t=[];var n=/-?(?:0|[1-9]\d*)?(?:\.\d*)?(?:[eE][+\-]?\d+)?/g;var r;while((r=n.exec(e))!==null){r.index===n.lastIndex&&n.lastIndex++;r[0]!==""&&t.push(parseFloat(r[0]))}return t}e.parseNumericList=t})(e.importer||(e.importer={}))})(c||(c={}));(function(e){(function(t){
/**
     * Renders an item in AutoDesk DFX file format.
     *
     * @param itemToExport Item to render: may be a path, an array of paths, or a model object.
     * @param options Rendering options object.
     * @param options.units String of the unit system. May be omitted. See makerjs.unitType for possible values.
     * @returns String of DXF content.
     */
function n(n,i){i===void 0&&(i={});var o={fontSize:9};var s=[];var u={entities:[],header:{},tables:{}};e.extendObject(o,i);if(e.isModel(n)){var l=n;l.exporterOptions&&e.extendObject(o,l.exporterOptions.toDXF)}function c(e){return o.layerOptions&&o.layerOptions[e]?o.layerOptions[e]:e in t.colors?{color:t.colors[e]}:void 0}function p(e){return o.layerOptions&&o.layerOptions[e]&&o.layerOptions[e].lineType?o.layerOptions[e].lineType:"CONTINUOUS"}function f(e,t){var n=e&&e.layer||t||"0";s.indexOf(n)<0&&s.push(n);return n}var h={};h[e.pathType.Line]=function(t,n,r){var a=f(t,r);var i={type:"LINE",layer:a,vertices:[{x:e.round(t.origin[0]+n[0],o.accuracy),y:e.round(t.origin[1]+n[1],o.accuracy)},{x:e.round(t.end[0]+n[0],o.accuracy),y:e.round(t.end[1]+n[1],o.accuracy)}]};i.lineType=p(a);return i};h[e.pathType.Circle]=function(t,n,r){var a=f(t,r);var i={type:"CIRCLE",layer:a,center:{x:e.round(t.origin[0]+n[0],o.accuracy),y:e.round(t.origin[1]+n[1],o.accuracy)},radius:e.round(t.radius,o.accuracy)};i.lineType=p(a);return i};h[e.pathType.Arc]=function(t,n,r){var a=f(t,r);var i={type:"ARC",layer:a,center:{x:e.round(t.origin[0]+n[0],o.accuracy),y:e.round(t.origin[1]+n[1],o.accuracy)},radius:e.round(t.radius,o.accuracy),startAngle:e.round(t.startAngle,o.accuracy),endAngle:e.round(t.endAngle,o.accuracy)};i.lineType=p(a);return i};function v(t,n,r){var a={type:"VERTEX",layer:f(null,n),x:e.round(t[0],o.accuracy),y:e.round(t[1],o.accuracy),bulge:r};return a}function d(t){var n={type:"POLYLINE",layer:f(null,t.layer),shape:t.chain.endless,vertices:[]};n.lineType=p(n.layer);t.chain.links.forEach((function(r,a){var i;if(r.walkedPath.pathContext.type===e.pathType.Arc){var s=r.walkedPath.pathContext;i=e.round(Math.tan(e.angle.toRadians(e.angle.ofArcSpan(s))/4),o.accuracy);r.reversed&&(i*=-1)}var u=r.endPoints[r.reversed?1:0];n.vertices.push(v(u,t.layer,i))}));if(!t.chain.endless){var r=t.chain.links[t.chain.links.length-1];var a=r.endPoints[r.reversed?0:1];n.vertices.push(v(a,t.layer))}return n}function g(t){var n=f(null,t.layer);var r=c(n);var a=e.point.middle(t.anchor);var i={type:"TEXT",startPoint:v(a,null),endPoint:v(a,null),layer:n,textHeight:r&&r.fontSize||o.fontSize,text:t.text,halign:4,valign:0,rotation:e.angle.ofPointInDegrees(t.anchor.origin,t.anchor.end)};return i}function m(e,t){var n={name:e,color:t};n.lineType=p(e);return n}function y(){var e={lineTypes:{CONTINUOUS:{name:"CONTINUOUS",description:"______",patternLength:0,elements:[]},DASHED:{name:"DASHED",description:"_ _ _ ",elements:[5,-2.5],patternLength:7.5},DOTTED:{name:"DOTTED",description:". . . ",elements:[.5,-1],patternLength:1.5}}};var t="lineType";u.tables[t]=e}function A(){var e={layers:{}};s.forEach((function(t){var n=c(t);n&&(e.layers[t]=m(t,n.color))}));var t="layer";u.tables[t]=e}function P(){if(o.units){var e=a[o.units];u.header.$INSUNITS=e}}function w(e,t,n){var r=u.entities;r.push.apply(r,t.map(d));e.forEach((function(e){var t=h[e.pathContext.type];if(t){var n=t(e.pathContext,e.offset,e.layer);r.push(n)}}));r.push.apply(r,n.map(g))}if(!o.units){var T=t.tryGetModelUnits(n);T&&(o.units=T)}e.extendObject(i,o);var x=[];var C=[];if(o.usePOLYLINE){var b=function(t,n,r){t.forEach((function(t){if(t.endless&&t.links.length===1&&t.links[0].walkedPath.pathContext.type===e.pathType.Circle)C.push(t.links[0].walkedPath);else{var n={chain:t,layer:r};x.push(n)}}));C.push.apply(C,n)};e.model.findChains(l,b,{byLayers:true,pointMatchingDistance:o.pointMatchingDistance})}else{var k={onPath:function(e){C.push(e)}};e.model.walk(l,k)}w(C,x,e.model.getAllCaptionsOffset(l));P();y();A();return r(u)}t.toDXF=n;function r(e){var t=[];function n(){var e=[];for(var n=0;n<arguments.length;n++)e[n]=arguments[n];t.push.apply(t,e)}function r(e){var t=e.lineType;t&&n("6",t)}var a={};a.LINE=function(e){n("0","LINE","8",e.layer);r(e);n("10",e.vertices[0].x,"20",e.vertices[0].y,"11",e.vertices[1].x,"21",e.vertices[1].y)};a.CIRCLE=function(e){n("0","CIRCLE","8",e.layer);r(e);n("10",e.center.x,"20",e.center.y,"40",e.radius)};a.ARC=function(e){n("0","ARC","8",e.layer);r(e);n("10",e.center.x,"20",e.center.y,"40",e.radius,"50",e.startAngle,"51",e.endAngle)};a.VERTEX=function(e){n("0","VERTEX","8",e.layer,"10",e.x,"20",e.y);e.bulge!==void 0&&n("42",e.bulge)};a.POLYLINE=function(e){n("0","POLYLINE","8",e.layer);r(e);n("66",1,"70",e.shape?1:0);e.vertices.forEach((function(e){return a.VERTEX(e)}));n("0","SEQEND")};a.TEXT=function(e){n("0","TEXT","10",e.startPoint.x,"20",e.startPoint.y,"11",e.endPoint.x,"21",e.endPoint.y,"40",e.textHeight,"1",e.text,"50",e.rotation,"8",e.layer,"72",e.halign,"73",e.valign)};function i(e){n("0","SECTION");e();n("0","ENDSEC")}function o(e){n("0","TABLE");e();n("0","ENDTAB")}function s(){n("2","TABLES");o(c);o(p)}function u(e){var t=e.lineType||"CONTINUOUS";n("0","LAYER","2",e.name,"70","0","62",e.color,"6",t)}function l(e){var t=e.elements||[];n("0","LTYPE","72","65","70","0","2",e.name,"3",e.description,"73",t.length,"40",e.patternLength);t.forEach((function(e){return n("49",e)}))}function c(){var t="lineType";var r=e.tables[t];n("2","LTYPE");for(var a in r.lineTypes){var i=r.lineTypes[a];l(i)}}function p(){var t="layer";var r=e.tables[t];n("2","LAYER");for(var a in r.layers){var i=r.layers[a];u(i)}}function f(){n("2","HEADER");for(var t in e.header){var r=e.header[t];n("9",t,"70",r)}}function h(e){n("2","ENTITIES");e.forEach((function(e){var t=a[e.type];t&&t(e)}))}i(f);i(s);i((function(){return h(e.entities)}));n("0","EOF");return t.join("\n")}var a={};a[""]=0;a[e.unitType.Inch]=1;a[e.unitType.Foot]=2;a[e.unitType.Millimeter]=4;a[e.unitType.Centimeter]=5;a[e.unitType.Meter]=6})(e.exporter||(e.exporter={}))})(c||(c={}));(function(e){(function(t){var n=Math.sqrt(3)/2;
/**
     * Solves for the altitude of an equilateral triangle when you know its side length.
     *
     * @param sideLength Length of a side of the equilateral triangle (all 3 sides are equal).
     * @returns Altitude of the equilateral triangle.
     */function r(e){return e*n}t.equilateralAltitude=r;
/**
     * Solves for the side length of an equilateral triangle when you know its altitude.
     *
     * @param altitude Altitude of the equilateral triangle.
     * @returns Length of the side of the equilateral triangle (all 3 sides are equal).
     */function a(e){return e/n}t.equilateralSide=a;
/**
     * Solves for the angle of a triangle when you know lengths of 3 sides.
     *
     * @param lengthA Length of side of triangle, opposite of the angle you are trying to find.
     * @param lengthB Length of any other side of the triangle.
     * @param lengthC Length of the remaining side of the triangle.
     * @returns Angle opposite of the side represented by the first parameter.
     */function i(t,n,r){return e.angle.toDegrees(Math.acos((n*n+r*r-t*t)/(2*n*r)))}t.solveTriangleSSS=i;
/**
     * Solves for the length of a side of a triangle when you know length of one side and 2 angles.
     *
     * @param oppositeAngleInDegrees Angle which is opposite of the side you are trying to find.
     * @param lengthOfSideBetweenAngles Length of one side of the triangle which is between the provided angles.
     * @param otherAngleInDegrees An other angle of the triangle.
     * @returns Length of the side of the triangle which is opposite of the first angle parameter.
     */function o(t,n,r){var a=180-t-r;return n*Math.sin(e.angle.toRadians(t))/Math.sin(e.angle.toRadians(a))}t.solveTriangleASA=o;
/**
     * Solves for the angles of the tangent lines between 2 circles.
     *
     * @param a First circle.
     * @param b Second circle.
     * @param inner Boolean to use inner tangents instead of outer tangents.
     * @returns Array of angles in degrees where 2 lines between the circles will be tangent to both circles.
     */function s(t,n,r){r===void 0&&(r=false);var a=new e.paths.Line(t.origin,n.origin);var i=e.measure.pointDistance(t.origin,n.origin);if(t.radius>=i+n.radius||n.radius>=i+t.radius)return null;if(r&&t.radius+n.radius>=i)return null;var o;if(r||e.round(t.radius-n.radius)!=0){var s=i/2;var u=new e.paths.Circle([s,0],s);var l=new e.paths.Circle(t.radius>n.radius?[0,0]:[i,0],r?t.radius+n.radius:Math.abs(t.radius-n.radius));var c=e.path.intersection(l,u);if(!c||!c.path1Angles)return null;o=c.path1Angles}else o=[90,270];var p=e.angle.ofLineInDegrees(a);return o.map((function(t){return e.angle.noRevolutions(t+p)}))}t.circleTangentAngles=s})(e.solvers||(e.solvers={}))})(c||(c={}));(function(e){(function(t){var n={};n[e.pathType.Arc]={};n[e.pathType.Circle]={};n[e.pathType.Line]={};n[e.pathType.Arc][e.pathType.Arc]=function(t,n,a,i){var o=null;r([t,n],a,i,(function(){var r=c(t,n,a);if(r){var i=u(r[0],t,a);var l=u(r[1],n,a);if(i&&l)if(i.length===1||l.length===1)for(var p=0;p<i.length;p++)for(var f=0;f<l.length;f++){var h=e.point.fromAngleOnCircle(i[p],t);var v=e.point.fromAngleOnCircle(l[f],n);if(e.measure.isPointEqual(h,v,1e-4)){o={intersectionPoints:[h],path1Angles:[i[p]],path2Angles:[l[f]]};return}}else o={intersectionPoints:s(i,t),path1Angles:i,path2Angles:l}}else a.out_AreOverlapped&&(a.out_AreOverlapped=e.measure.isArcOverlapping(t,n,a.excludeTangents))}));return o};n[e.pathType.Arc][e.pathType.Circle]=function(e,t,n,a){var i=null;r([e,t],n,a,(function(){var r=c(e,t,n);if(r){var a=u(r[0],e,n);if(a){var l;if(a.length==2)l=r[1];else{var p=o(r[0],a[0]);l=[r[1][p]]}i={intersectionPoints:s(a,e),path1Angles:a,path2Angles:l}}}}));return i};n[e.pathType.Arc][e.pathType.Line]=function(e,t,n,a){var i=null;r([e,t],n,a,(function(){var r=l(t,e,n);if(r){var a=u(r,e,n);a&&(i={intersectionPoints:s(a,e),path1Angles:a})}}));return i};n[e.pathType.Circle][e.pathType.Arc]=function(t,r,i){var o=n[e.pathType.Arc][e.pathType.Circle](r,t,i,true);return o?a(o):null};n[e.pathType.Circle][e.pathType.Circle]=function(e,t,n,a){var i=null;r([e,t],n,a,(function(){var r=c(e,t,n);r&&(i={intersectionPoints:s(r[0],e),path1Angles:r[0],path2Angles:r[1]})}));return i};n[e.pathType.Circle][e.pathType.Line]=function(e,t,n,a){var i=null;r([e,t],n,a,(function(){var r=l(t,e,n);r&&(i={intersectionPoints:s(r,e),path1Angles:r})}));return i};n[e.pathType.Line][e.pathType.Arc]=function(t,r,i){var o=n[e.pathType.Arc][e.pathType.Line](r,t,i,true);return o?a(o):null};n[e.pathType.Line][e.pathType.Circle]=function(t,r,i){var o=n[e.pathType.Circle][e.pathType.Line](r,t,i,true);return o?a(o):null};n[e.pathType.Line][e.pathType.Line]=function(t,n,a,i){var o=null;r([t,n],a,i,(function(){var r=e.point.fromSlopeIntersection(t,n,a);r&&e.measure.isBetweenPoints(r,t,a.excludeTangents)&&e.measure.isBetweenPoints(r,n,a.excludeTangents)&&(o={intersectionPoints:[r]})}));return o};function r(e,n,r,a){var i=r?[n.path2Offset,n.path1Offset]:[n.path1Offset,n.path2Offset];t.moveTemporary(e,i,a)}function a(e){var t=e.path1Angles;e.path2Angles?e.path1Angles=e.path2Angles:delete e.path1Angles;t&&(e.path2Angles=t);return e}
/**
     * Find the point(s) where 2 paths intersect.
     *
     * @param path1 First path to find intersection.
     * @param path2 Second path to find intersection.
     * @param options Optional IPathIntersectionOptions.
     * @returns IPathIntersection object, with points(s) of intersection (and angles, when a path is an arc or circle); or null if the paths did not intersect.
     */function i(e,t,r){r===void 0&&(r={});if(e&&t){var a=n[e.type][t.type];if(a)return a(e,t,r)}return null}t.intersection=i;function o(e,t){for(var n=2;n--;)if(e[n]===t)return n}function s(t,n){var r=[];for(var a=0;a<t.length;a++)r.push(e.point.fromAngleOnCircle(t[a],n));return r}function u(t,n,r){if(!t)return null;var a=[];for(var i=0;i<t.length;i++)e.measure.isBetweenArcAngles(t[i],n,r.excludeTangents)&&a.push(t[i]);return a.length==0?null:a}function l(n,r,a){var i=e.round(r.radius);if(r.radius<=0)return null;var o=new e.paths.Line(e.point.subtract(n.origin,r.origin),e.point.subtract(n.end,r.origin));var s=e.angle.ofLineInDegrees(n);var u=s>=180?s-360:s;t.rotate(o,-u,e.point.zero());function l(t){var n=t+u;return e.round(e.angle.noRevolutions(n))}var c=e.round(o.origin[1]);var p=Math.abs(c);if(p>i)return null;var f=[];if(p==i){if(a.excludeTangents)return null;f.push(l(c>0?90:270))}else{function g(t,n){e.measure.isBetween(e.round(t),e.round(o.origin[0]),e.round(o.end[0]),a.excludeTangents)&&f.push(l(n))}var h=Math.asin(c/i);var v=e.angle.toDegrees(h);var d=Math.cos(h)*i;g(-d,180-v);g(d,v)}return f.length>0?f:null}function c(n,r,a){if(n.radius<=0||r.radius<=0)return null;if(n.radius==r.radius&&e.measure.isPointEqual(n.origin,r.origin,1e-4)){a.out_AreOverlapped=true;return null}e.point.subtract(e.point.zero(),n.origin);var i=new e.paths.Circle(e.point.zero(),n.radius);var o=new e.paths.Circle(e.point.subtract(r.origin,n.origin),r.radius);var s=e.angle.ofPointInDegrees(e.point.zero(),o.origin);t.rotate(o,-s,e.point.zero());function u(t){var n=t+s;return e.angle.noRevolutions(n)}var l=o.origin[0];if(e.round(o.radius-l-i.radius)==0)return a.excludeTangents?null:[[u(180)],[u(180)]];if(e.round(o.radius+l-i.radius)==0)return a.excludeTangents?null:[[u(0)],[u(0)]];if(e.round(l-o.radius-i.radius)==0)return a.excludeTangents?null:[[u(0)],[u(180)]];if(e.round(l-o.radius)>i.radius)return null;if(e.round(l+o.radius)<i.radius)return null;if(e.round(l-o.radius)<-i.radius)return null;function c(t){return[u(t),u(e.angle.mirror(t,false,true))]}var p=e.solvers.solveTriangleSSS(o.radius,i.radius,l);var f=e.solvers.solveTriangleSSS(i.radius,l,o.radius);return[c(p),c(180-f)]}})(e.path||(e.path={}))})(c||(c={}));(function(e){(function(t){var n={};n[e.pathType.Arc]=function(e){return["startAngle","endAngle"]};n[e.pathType.Line]=function(e){return["origin","end"]};function r(t){var r=e.point.fromPathEnds(t);if(r){function o(e){return{point:r[e],propertyName:a[e]}}var a=null;var i=n[t.type];if(i){a=i(t);return[o(0),o(1)]}}return null}function a(t,n,a){var i=r(t);var o=r(n);var s=null;function u(e,t,n){return{path:e,isStart:n==0,propertyName:t[n].propertyName,point:t[n].point,oppositePoint:t[1-n].point}}function l(r,a){if(e.measure.isPointEqual(i[r].point,o[a].point,1e-4)){s=[u(t,i,r),u(n,o,a)];return true}return false}l(0,0)||l(0,1)||l(1,0)||l(1,1);return s}function i(n,r,a,i){var o=new e.paths.Circle(r,n);for(var s=0;s<2;s++){var u=t.intersection(o,a[s].path);if(!u)return false;a[s].shardPoint=u.intersectionPoints[0];if(e.measure.isPointEqual(a[s].point,u.intersectionPoints[0],1e-4)){if(!(u.intersectionPoints.length>1))return false;a[s].shardPoint=u.intersectionPoints[1]}}return true}function o(e,n){var r=t.clone(e);var a=t.breakAtPoint(r,n);return[r,a]}var s={};s[e.pathType.Arc]=function(t,n,r,a,i){var s=t.radius;var u=o(t,a)[i?0:1];if(u){e.measure.isArcConcaveTowardsPoint(u,r)?s-=n:s+=n;return e.round(s)<=0?null:new e.paths.Arc(t.origin,s,t.startAngle,t.endAngle)}return null};s[e.pathType.Line]=function(t,n,r,a,i){return new e.paths.Parallel(t,n,r)};function u(e,t,n){var r=null;var a=s[e.path.type];a&&(r=a(e.path,t,n,e.shardPoint,e.isStart));return r}var l={};l[e.pathType.Arc]=function(t,n,r,a){var i=new e.paths.Line(t.origin,a);var o=e.angle.ofLineInDegrees(i);var s=o;e.measure.isArcConcaveTowardsPoint(t,a)||(s+=180);return{filletAngle:e.angle.noRevolutions(s),clipPath:function(){t[n]=o}}};l[e.pathType.Line]=function(n,r,a,i){var o=new e.paths.Line([0,0],[0,1]);var s=e.angle.ofLineInDegrees(n);t.rotate(o,s,[0,0]);t.moveRelative(o,i);var u=e.point.fromSlopeIntersection(n,o);return u?{filletAngle:e.angle.ofPointInDegrees(i,u),clipPath:function(){n[r]=u}}:null};function c(e,t,n){var r=null;var a=l[e.path.type];a&&(r=a(e.path,e.propertyName,t,n));f(e,r)||(r=null);return r}function p(t,n){var r={filletAngle:e.angle.ofPointInDegrees(n,t.shardPoint),clipPath:function(){t.path[t.propertyName]=t.shardPoint}};f(t,r)||(r=null);return r}function f(t,n){var r=false;if(n){var a=t.path[t.propertyName];n.clipPath();e.measure.pathLength(t.path)>0&&(r=true);t.path[t.propertyName]=a}return r}function h(t){var n=0;var r=[];for(var a=0;a<t.length;a++){var i=e.measure.pathLength(t[a]);r.push(i);n+=i}return r[0]/n}
/**
     * Adds a round corner to the outside angle between 2 lines. The lines must meet at one point.
     *
     * @param lineA First line to fillet, which will be modified to fit the fillet.
     * @param lineB Second line to fillet, which will be modified to fit the fillet.
     * @returns Arc path object of the new fillet.
     */function v(t,n,r,o){if(e.isPathLine(t)&&e.isPathLine(n)&&r&&r>0){var s={pointMatchingDistance:.005};e.extendObject(s,o);var u=a(t,n,o);if(u){var l=h([t,n]);var c=new e.paths.Line(u[0].oppositePoint,u[1].oppositePoint);var f=e.point.middle(c,l);var v=e.angle.ofPointInDegrees(u[0].point,f);var d=e.point.add(u[0].point,e.point.fromPolar(e.angle.toRadians(v),r));if(!i(r,d,u,s))return null;var g=[];for(var m=0;m<2;m++){var y=p(u[m],d);if(!y)return null;g.push(y)}var A=new e.paths.Arc(d,r,g[0].filletAngle,g[1].filletAngle);if(e.round(e.angle.noRevolutions(e.angle.ofArcMiddle(A)))==e.round(v)){A.startAngle=g[1].filletAngle;A.endAngle=g[0].filletAngle}g[0].clipPath();g[1].clipPath();return A}}return null}t.dogbone=v;
/**
     * Adds a round corner to the inside angle between 2 paths. The paths must meet at one point.
     *
     * @param pathA First path to fillet, which will be modified to fit the fillet.
     * @param pathB Second path to fillet, which will be modified to fit the fillet.
     * @param filletRadius Radius of the fillet.
     * @param options Optional IPointMatchOptions object to specify pointMatchingDistance.
     * @returns Arc path object of the new fillet.
     */function d(n,r,o,s){if(n&&r&&o&&o>0){var l={pointMatchingDistance:.005};e.extendObject(l,s);var p=a(n,r,s);if(p){if(!i(o,p[0].point,p,l))return null;var f=[];for(var h=0;h<2;h++){var v=p[1-h].shardPoint;if(!v)return null;var d=u(p[h],o,v);f.push(d)}var g=t.intersection(f[0],f[1]);if(g){var m;m=g.intersectionPoints.length==1?g.intersectionPoints[0]:e.point.closest(p[0].point,g.intersectionPoints);var y=[];for(h=0;h<2;h++){var A=c(p[h],o,m);if(!A)return null;y.push(A)}if(e.round(y[0].filletAngle-y[1].filletAngle)==0)return null;var P=new e.paths.Arc(m,o,y[0].filletAngle,y[1].filletAngle);var w=e.angle.ofArcSpan(P);if(w==180)return null;if(w>180){P.startAngle=y[1].filletAngle;P.endAngle=y[0].filletAngle}y[0].clipPath();y[1].clipPath();return P}}}return null}t.fillet=d})(e.path||(e.path={}))})(c||(c={}));(function(e){(function(t){function n(e,t){return a(false,e,t)}t.dogbone=n;function r(e,t){return a(true,e,t)}t.fillet=r;function a(t,n,r){var a={paths:{}};var i=0;var o=n.links;function s(n,s){var u=o[n].walkedPath,l=o[s].walkedPath;u.modelContext===l.modelContext&&u.modelContext.type==e.models.BezierCurve.typeName||e.path.moveTemporary([u.pathContext,l.pathContext],[u.offset,l.offset],(function(){var c;if(e.isObject(r)){var p=e.angle.ofChainLinkJoint(o[n],o[s]);if(e.round(p)===0)return;c=p>0?r.left:r.right}else c=r;if(c&&!(c<0)){var f;f=t?e.path.fillet(u.pathContext,l.pathContext,c):e.path.dogbone(u.pathContext,l.pathContext,c);if(f){a.paths["fillet"+i]=f;i++}}}))}for(var u=1;u<o.length;u++)s(u-1,u);n.endless&&s(u-1,0);return i?a:null}})(e.chain||(e.chain={}))})(c||(c={}));(function(e){(function(e){
/**
     * Helper function to use the JavaScript "apply" function in conjunction with the "new" keyword.
     *
     * @param ctor The constructor for the class which is an IKit.
     * @param args The array of parameters passed to the constructor.
     * @returns A new instance of the class, which implements the IModel interface.
     */
function t(e,t){function n(){return e.apply(this||u,t)}n.prototype=e.prototype;return new n}e.construct=t;
/**
     * Extract just the initial sample values from a kit.
     *
     * @param ctor The constructor for the class which is an IKit.
     * @returns Array of the inital sample values provided in the metaParameters array.
     */function n(e){var t=[];var n=e.metaParameters;if(n)for(var r=0;r<n.length;r++){var a=n[r].value;Array.isArray(a)&&(a=a[0]);t.push(a)}return t}e.getParameterValues=n})(e.kit||(e.kit={}))})(c||(c={}));(function(e){(function(t){function n(e,t){return e[0].walkedPath.pathContext===t?e[1]:e[0]}function r(e,t,r){function a(t,r,a){while(t){r.links.push(t);r.pathLength+=t.pathLength;var i=t.reversed?0:1;var o=t.endPoints[i];var s=e.getElementAtPoint(o);if(!s||s.valueIds.length===0)break;var u=s.valueIds.map((function(t){return e.values[t]}));var l=n(u,t.walkedPath.pathContext);s.valueIds.splice(0,2);if(!l)break;if(l.walkedPath.pathContext===a.walkedPath.pathContext){r.links.length>1&&(r.endless=true);break}t=l}}e.forEachPoint((function(e,n,i,o){if(o.valueIds.length>0){var s={links:[],pathLength:0};a(n[0],s,n[0]);if(s.endless)t(s,false);else{s.links.reverse();var u=s.links[0];s.links.map((function(e){e.reversed=!e.reversed}));s.pathLength-=s.links[s.links.length-1].pathLength;var l=s.links.pop();a(l,s,u);s.links.length>1?t(s,true):r(s.links[0].walkedPath)}}}))}
/**
     * Find a single chain within a model, across all layers. Shorthand of findChains; useful when you know there is only one chain to find in your model.
     *
     * @param modelContext The model to search for a chain.
     * @returns A chain object or null if chains were not found.
     */function a(e){var t=null;o(e,(function(e,n,r){t=e[0]}),{byLayers:false});return t}t.findSingleChain=a;function i(e,t){var n=t===e.reversed?1:0;return e.endPoints[n]}function o(n){var a=[];for(var o=1;o<arguments.length;o++)a[o-1]=arguments[o];var c;var p;switch(a.length){case 1:typeof a[0]==="function"?p=a[0]:c=a[0];break;case 2:p=a[0];c=a[1];break}var f={pointMatchingDistance:.005};e.extendObject(f,c);var h={};var v={};var d={};var g={onPath:function(t){var n=f.byLayers?t.layer:"";h[n]||(h[n]=new e.PointGraph);var r=h[n];var a=e.measure.pathLength(t.pathContext);if(t.pathContext.type===e.pathType.Circle||t.pathContext.type===e.pathType.Arc&&e.round(e.angle.ofArcSpan(t.pathContext)-360)===0||t.pathContext.type===e.pathType.BezierSeed&&e.measure.isPointEqual(t.pathContext.origin,t.pathContext.end,f.pointMatchingDistance)){var i={links:[{walkedPath:t,reversed:null,endPoints:null,pathLength:a}],endless:true,pathLength:a};v[n]||(v[n]=[]);v[n].push(i)}else{if(a<f.pointMatchingDistance/5){d[n]||(d[n]=[]);d[n].push(t);return}var o=e.point.fromPathEnds(t.pathContext,t.offset);for(var s=0;s<2;s++){var u={walkedPath:t,endPoints:o,reversed:s!=0,pathLength:a};var l=r.insertValue(u);r.insertValueIdAtPoint(l,o[s])}}}};f.shallow&&(g.beforeChildWalk=function(){return false});var m;if(f.unifyBeziers){m=u(n);l(m,true,f.pointMatchingDistance)}t.walk(n,g);var y=function(t){var n=h[t];n.mergeNearestSinglePoints(f.pointMatchingDistance);A=[];v[t]||(v[t]=[]);r(n,(function(n,r){n.endless=r?e.measure.isPointEqual(i(n.links[0],true),i(n.links[n.links.length-1],false),f.pointMatchingDistance):!!n.endless;v[t].push(n)}),(function(e){A.push(e)}));v[t].sort((function(e,t){return t.pathLength-e.pathLength}));if(f.contain){P=e.isObject(f.contain)?f.contain:{alternateDirection:false};w=s(v[t],P);v[t]=w}p&&p(v[t],A,t,d[t])};var A,P,w;for(var T in h)y(T);m&&l(m,false,f.pointMatchingDistance);return f.byLayers?v:v[""]}t.findChains=o;function s(t,n){var r=t.map((function(t){return e.chain.toNewModel(t)}));var a=[];t.forEach((function(n,i){if(n.endless){var o=n.links[0].walkedPath;var s=e.path.clone(o.pathContext,o.offset);t.forEach((function(t,o){n!==t&&t.endless&&e.measure.isPointInsideModel(e.point.middle(s),r[o])&&(a[i]=t)}))}}));var i=[];t.forEach((function(e,t){var n=a[t];if(n){n.contains||(n.contains=[]);n.contains.push(e)}else i.push(e)}));if(n.alternateDirection){function o(t,n){t.forEach((function(t,r){var a=e.measure.isChainClockwise(t);a!==null&&(!a&&n||a&&!n)&&e.chain.reverse(t);t.contains&&o(t.contains,!n)}))}o(i,true)}return i}function u(n){var r=[];function a(t){t.childModel.type===e.models.BezierCurve.typeName&&r.push(t)}var i={beforeChildWalk:function(e){a(e);return true}};var o={childId:"",childModel:n,layer:n.layer,offset:n.origin,parentModel:null,route:[],routeKey:""};a(o);t.walk(n,i);return r}function l(t,n,r){var a="tempPaths";var i="tempLayer";t.forEach((function(t){var o=t.childModel;if(n){if(t.layer!=void 0&&t.layer!==""){o[i]=o.layer;o.layer=t.layer}var s=e.models.BezierCurve.getBezierSeeds(o,{byLayers:true,pointMatchingDistance:r});for(var u in s){var l=s[u];if(l.length>0){o[a]=o.paths;var c={};l.forEach((function(e,t){e.layer=u;c["seed_"+t]=e}));o.paths=c}}}else{if(a in o){o.paths=o[a];delete o[a]}if(i in o){o[i]==void 0?delete o.layer:o.layer=o[i];delete o[i]}}}))}})(e.model||(e.model={}))})(c||(c={}));(function(e){(function(t){
/**
     * Shift the links of an endless chain.
     *
     * @param chainContext Chain to cycle through. Must be endless.
     * @param amount Optional number of links to shift. May be negative to cycle backwards.
     * @returns The chainContext for cascading.
     */
function n(e,t){t===void 0&&(t=1);if(e.endless){var n=Math.abs(t);for(var r=0;r<n;r++)t<0?e.links.push(e.links.shift()):e.links.unshift(e.links.pop());return e}}t.cycle=n;
/**
     * Reverse the links of a chain.
     *
     * @param chainContext Chain to reverse.
     * @returns The chainContext for cascading.
     */function r(e){e.links.reverse();e.links.forEach((function(e){return e.reversed=!e.reversed}));return e}t.reverse=r;
/**
     * Set the beginning of an endless chain to a known routeKey of a path.
     *
     * @param chainContext Chain to cycle through. Must be endless.
     * @param routeKey RouteKey of the desired path to start the chain with.
     * @returns The chainContext for cascading.
     */function a(e,t){if(e.endless){var r=-1;for(var a=0;a<e.links.length;a++)if(e.links[a].walkedPath.routeKey==t){r=a;break}r>0&&n(e,r);return e}}t.startAt=a;
/**
     * Convert a chain to a new model, independent of any model from where the chain was found.
     *
     * @param chainContext Chain to convert to a model.
     * @param detachFromOldModel Flag to remove the chain's paths from their current parent model. If false, each path will be cloned. If true, the original path will be re-parented into the resulting new model. Default is false.
     * @returns A new model containing paths from the chain.
     */function i(t,n){n===void 0&&(n=false);var r={paths:{}};for(var a=0;a<t.links.length;a++){var i=t.links[a].walkedPath;if(i.pathContext.type===e.pathType.BezierSeed){n&&delete i.modelContext.paths[i.pathId];r.models||(r.models={});var o=e.model.getSimilarModelId(r,i.pathId);r.models[o]=e.model.moveRelative(new e.models.BezierCurve(i.pathContext),i.offset)}else{var s;if(n){s=i.pathContext;delete i.modelContext.paths[i.pathId]}else s=e.path.clone(i.pathContext);var u=e.model.getSimilarPathId(r,i.pathId);r.paths[u]=e.path.moveRelative(s,i.offset)}}return r}t.toNewModel=i;function o(t,n){!t||n.length<2||e.measure.isPointEqual(n[0],n[n.length-1],1e-5)&&n.pop()}
/**
     * Get points along a chain of paths.
     *
     * @param chainContext Chain of paths to get points from.
     * @param distance Numeric distance along the chain between points, or numeric array of distances along the chain between each point.
     * @param maxPoints Maximum number of points to retrieve.
     * @returns Array of points which are on the chain spread at a uniform interval.
     */function s(t,n,r){var a=[];var i=0;var s=0;var u;Array.isArray(n)&&(u=n);for(var l=0;l<t.links.length;l++){var c=t.links[l];var p=c.walkedPath;var f=c.pathLength;while(e.round(f-s)>0){var h=s/f;c.reversed&&(h=1-h);a.push(e.point.add(e.point.middle(p.pathContext,h),p.offset));if(r&&a.length>=r)return a;var v;if(u){v=u[i];i++;if(i>u.length)return a}else v=n;s+=v}s-=f}o(t.endless,a);return a}t.toPoints=s;
/**
     * Get key points (a minimal a number of points) along a chain of paths.
     *
     * @param chainContext Chain of paths to get points from.
     * @param maxArcFacet The maximum length between points on an arc or circle.
     * @returns Array of points which are on the chain.
     */function u(t,n){var r=[];for(var a=0;a<t.links.length;a++){var i=t.links[a];var s=i.walkedPath;var u=e.path.toKeyPoints(s.pathContext,n);if(u.length>0){i.reversed&&u.reverse();a>0&&u.shift();var l=u.map((function(t){return e.point.add(t,s.offset)}));r.push.apply(r,l)}}o(t.endless,r);return r}t.toKeyPoints=u})(e.chain||(e.chain={}))})(c||(c={}));(function(e){(function(t){var n=function(){function n(t,n){(this||u).modelContext=t;(this||u).options=n;(this||u).pointMap=new e.PointGraph;(this||u).list=[];(this||u).removed=[];(this||u).ordinals={};this.load()}n.prototype.load=function(){var n=this||u;var r={onPath:function(t){var r=e.point.fromPathEnds(t.pathContext,t.offset);if(r){var a=t;a.endPoints=r;var i=n.pointMap.insertValue(a);for(var o=2;o--;)n.pointMap.insertValueIdAtPoint(i,r[o])}}};t.walk((this||u).modelContext,r);(this||u).options.pointMatchingDistance&&(this||u).pointMap.mergePoints((this||u).options.pointMatchingDistance)};n.prototype.findDeadEnds=function(){var e=this||u;var t=0;(this||u).pointMap.forEachPoint((function(n,r,a,i){e.ordinals[a]=t++;e.list.push(i)}));t=0;var n=function(){var n=r.list[t];n.valueIds.length===1?r.removePath(n,n.valueIds[0],t):r.options.keep&&n.valueIds.length%2&&n.valueIds.forEach((function(r){var a=e.pointMap.values[r];e.options.keep(a)||e.removePath(n,r,t)}));t++};var r=this||u;while(t<(this||u).list.length)n();return(this||u).removed};n.prototype.removePath=function(e,t,n){var r=(this||u).pointMap.values[t];var a=this.getOtherPointId(r.endPoints,e.pointId);var i=(this||u).pointMap.index[a];(this||u).removed.push(r);this.removeValue(e,t);this.removeValue(i,t);i.valueIds.length>0&&this.appendQueue(i,n)};n.prototype.removeValue=function(e,t){var n=e.valueIds.indexOf(t);n>=0&&e.valueIds.splice(n,1)};n.prototype.appendQueue=function(e,t){var n=(this||u).ordinals[e.pointId];if(n<t){(this||u).list[n]=null;(this||u).list.push(e);(this||u).ordinals[e.pointId]=(this||u).list.length}};n.prototype.getOtherPointId=function(e,t){for(var n=0;n<e.length;n++){var r=(this||u).pointMap.getIdOfPoint(e[n]);if(t!==r)return r}};return n}();
/**
     * Remove paths from a model which have endpoints that do not connect to other paths.
     *
     * @param modelContext The model to search for dead ends.
     * @param pointMatchingDistance Optional max distance to consider two points as the same.
     * @param keep Optional callback function (which should return a boolean) to decide if a dead end path should be kept instead.
     * @param trackDeleted Optional callback function which will log discarded paths and the reason they were discarded.
     * @returns The input model (for cascading).
     */function r(e,t,r,a){var i={pointMatchingDistance:t||.005,keep:r};var o=new n(e,i);var s=o.findDeadEnds();s.length<o.pointMap.values.length&&s.forEach((function(e){a(e,"dead end");delete e.modelContext.paths[e.pathId]}));return e}t.removeDeadEnds=r})(e.model||(e.model={}))})(c||(c={}));(function(e){(function(e){var t=function(){
/**
       * @param name Name of the XML tag.
       * @param attrs Optional attributes for the tag.
       */
function e(e,t){(this||u).name=e;(this||u).attrs=t;(this||u).innerText=""}
/**
       * Escapes certain characters within a string so that it can appear in a tag or its attribute.
       *
       * @returns Escaped string.
       */e.escapeString=function(e){var t={"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"};for(var n in t)e=e.split(n).join(t[n]);return e};
/**
       * Get the opening tag.
       *
       * @param selfClose Flag to determine if opening tag should be self closing.
       */e.prototype.getOpeningTag=function(t){var n="";function r(t,r){if(r!=null&&typeof r!=="undefined"){(Array.isArray(r)||typeof r==="object")&&(r=JSON.stringify(r));typeof r==="string"&&(r=e.escapeString(r));n+=" "+t+'="'+r+'"'}}for(var a in(this||u).attrs)r(a,(this||u).attrs[a]);return"<"+(this||u).name+n+(t?"/":"")+">"};e.prototype.getInnerText=function(){return(this||u).innerTextEscaped?(this||u).innerText:e.escapeString((this||u).innerText)};e.prototype.getClosingTag=function(){return"</"+(this||u).name+">"};e.prototype.toString=function(){var e=!(this||u).innerText;return e&&!(this||u).closingTags?this.getOpeningTag(true):this.getOpeningTag(false)+this.getInnerText()+this.getClosingTag()};return e}();e.XmlTag=t})(e.exporter||(e.exporter={}))})(c||(c={}));(function(e){(function(t){function n(e,t,n){return n?e+"("+t+")":t}function r(t,n){if(n){var r=new e.paths.Circle([0,0],t.radius);var a=e.measure.pathLength(r);if(a)return Math.ceil(a/n)}}function a(t,a,i){var o="";var s="";var u=true;var l=false;var c=false;var p={};p[e.pathType.Circle]=function(t,s){var u={center:e.point.rounded(e.point.add(t.origin,s.walkedPath.offset),i),radius:e.round(t.radius,i),resolution:r(t,a)};o=n("CAG.circle",JSON.stringify(u),true);l=true};p[e.pathType.Line]=function(t,r){var a=r.endPoints.map((function(t){return e.point.rounded(t,i)}));r.reversed&&a.reverse();o=n("new CSG.Path2D",JSON.stringify(a),true)};p[e.pathType.Arc]=function(t,s){var u=e.angle.ofArcEnd(t);s.reversed&&(c=true);var l={center:e.point.rounded(e.point.add(t.origin,s.walkedPath.offset),i),radius:e.round(t.radius,i),startangle:e.round(t.startAngle,i),endangle:e.round(u,i),resolution:r(t,a)};o=n("new CSG.Path2D.arc",JSON.stringify(l),true)};var f={};f[e.pathType.Line]=function(t,r){var a=c!=r.reversed;var o=e.point.rounded(r.endPoints[a?0:1],i);h(n(".appendPoint",JSON.stringify(o),true))};f[e.pathType.Arc]=function(t,o){var s=c!=o.reversed;var u=e.angle.ofArcEnd(t);var l={radius:e.round(t.radius,i),clockwise:s,large:Math.abs(u-t.startAngle)>180,resolution:r(t,a)};var p=e.point.rounded(o.endPoints[s?0:1],i);h(n(".appendArc",JSON.stringify(p)+","+JSON.stringify(l),true))};function h(e){c?s=e+s:s+=e}for(var v=0;v<t.links.length;v++){var d=t.links[v];var g=d.walkedPath.pathContext;var m=u?p[g.type]:f[g.type];m&&m(g,d);if(l)return o;u=false}return o+s+".close().innerToCAG()"}function i(e,t,n){return function(r){e&&e({progress:t+r.progress*n/100})}}
/**
     * Converts a model to a @jscad/csg CAG object - 2D to 2D. See https://en.wikibooks.org/wiki/OpenJSCAD_User_Guide#2D_Paths
     *
     * Example:
     * ```
     * //First, use npm install @jscad/csg from the command line in your jscad project
     * //Create a CAG instance from a model.
     * var { CAG } = require('@jscad/csg');
     * var model = new makerjs.models.Ellipse(70, 40);
     * var cag = makerjs.exporter.toJscadCAG(CAG, model, {maxArcFacet: 1});
     * ```
     *
     * @param jscadCAG @jscad/csg CAG engine, see https://www.npmjs.com/package/@jscad/csg
     * @param modelToExport Model object to export.
     * @param options Optional options object.
     * @param options.byLayers Optional flag to separate chains by layers.
     * @param options.pointMatchingDistance Optional max distance to consider two points as the same.
     * @param options.maxArcFacet The maximum length between points on an arc or circle.
     * @param options.statusCallback Optional callback function to get the percentage complete.
     * @returns jscad CAG object in 2D, or a map (keyed by layer id) of jscad CAG objects - if options.byLayers is true.
     */function o(t,n,r){function a(n,r){var a=e.chain.toKeyPoints(n,r);a.push(a[0]);return t.fromPoints(a)}function i(e,t){return e.union(t)}function o(e,t){return e.subtract(t)}return s(a,i,o,n,r)}t.toJscadCAG=o;function s(t,n,r,a,i){i===void 0&&(i={});var o={};var s={total:0,complete:0};function u(e,t,r){var a=r.shift();r.forEach((function(e){return a=n(a,e)}));s.complete++;i.statusCallback&&i.statusCallback({progress:e+t*s.complete/s.total});return a}function l(e,n){var r=[];n.forEach((function(n){if(n.endless){n.contains&&c(e,n.contains);s.total++;r.unshift(t(n,i.maxArcFacet))}}));return r}function c(e,n){n.forEach((function(n){if(n.endless){var r={cag:t(n,i.maxArcFacet),subtracts:[]};if(n.contains){var a=l(e,n.contains);a.length>0&&r.subtracts.push(a)}s.total++;e in o||(o[e]=[]);o[e].unshift(r)}}))}var p={pointMatchingDistance:i.pointMatchingDistance,byLayers:i.byLayers,contain:true};i.statusCallback&&i.statusCallback({progress:25});var f=e.model.findChains(a,p);if(Array.isArray(f))c("",f);else for(var h in f)c(h,f[h]);i.statusCallback&&i.statusCallback({progress:50});var v=0;for(var h in o)v+=o[h].length;if(v===0){i.statusCallback&&i.statusCallback({progress:100});throw"No closed geometries found."}var d={};for(var h in o){var g=o[h].map((function(e){var t=e.cag;e.subtracts.forEach((function(e){var n=u(50,50,e);t=r(t,n)}));return t}));d[h]=u(50,50,g)}i.statusCallback&&i.statusCallback({progress:100});return p.byLayers?d:d[""]}
/**
     * Converts a model to a @jscad/csg CSG object - 2D to 3D.
     *
     * Example:
     * ```
     * //First, use npm install @jscad/csg from the command line in your jscad project
     * //Create a CSG instance from a model.
     * var { CAG } = require('@jscad/csg');
     * var model = new makerjs.models.Ellipse(70, 40);
     * var csg = makerjs.exporter.toJscadCSG(CAG, model, {maxArcFacet: 1, extrude: 10});
     * ```
     *
     * @param jscadCAG @jscad/csg CAG engine, see https://www.npmjs.com/package/@jscad/csg
     * @param modelToExport Model object to export.
     * @param options Optional options object.
     * @param options.byLayers Optional flag to separate chains by layers.
     * @param options.pointMatchingDistance Optional max distance to consider two points as the same.
     * @param options.maxArcFacet The maximum length between points on an arc or circle.
     * @param options.statusCallback Optional callback function to get the percentage complete.
     * @param options.extrude Optional default extrusion distance.
     * @param options.layerOptions Optional object map of options per layer, keyed by layer name. Each value for a key is an object with 'extrude' and 'z' properties.
     * @returns jscad CAG object in 2D, or a map (keyed by layer id) of jscad CAG objects - if options.byLayers is true.
     */function u(e,t,n){function r(n){return o(e,t,n)}function a(e,t,n){var r=e.extrude({offset:[0,0,t]});n&&(r=r.translate([0,0,n]));return r}function i(e,t){return e.union(t)}return l(r,a,i,t,n)}t.toJscadCSG=u;function l(t,n,r,a,o){o===void 0&&(o={});var s=o.statusCallback;function u(t,n){return e.isNumber(t)?t:n}a.exporterOptions&&e.extendObject(o,a.exporterOptions.toJscadCSG);o.byLayers=o.byLayers||o.layerOptions&&true;o.statusCallback=i(s,0,50);var l=t(o);var c=[];if(o.byLayers)for(var p in l){var f=o.layerOptions[p];var h=n(l[p],f.extrude||o.extrude,u(f.z,o.z));c.push(h)}else{h=n(l,o.extrude,o.z);c.push(h)}o.statusCallback=i(s,50,100);var v={total:c.length-1,complete:0};var d=c.shift();c.forEach((function(e,t){d=r(d,e);v.complete++;o.statusCallback({progress:v.complete/v.total})}));return d}
/**
     * Creates a string of JavaScript code for execution with a Jscad environment.
     *
     * @param modelToExport Model object to export.
     * @param options Export options object.
     * @param options.byLayers Optional flag to separate chains by layers.
     * @param options.pointMatchingDistance Optional max distance to consider two points as the same.
     * @param options.maxArcFacet The maximum length between points on an arc or circle.
     * @param options.statusCallback Optional callback function to get the percentage complete.
     * @param options.extrude Optional default extrusion distance.
     * @param options.layerOptions Optional object map of options per layer, keyed by layer name. Each value for a key is an object with 'extrude' and 'z' properties.
     * @returns String of JavaScript containing a main() function for Jscad.
     */function c(e,t){t===void 0&&(t={});function n(e,n){return c(a(e,n,t.accuracy))}function r(e,t){return e+".union(".concat(t,")")}function i(e,t){return e+".subtract(".concat(t,")")}function o(a){return s(n,r,i,e,t)}function u(e,t,n){var r=e+".extrude({ offset: [0, 0, ".concat(t,"] })");n&&(r+=".translate([0, 0, ".concat(n,"])"));return r}function c(e){return"".concat(f).concat(p).concat(e).concat(f)}var p=new Array((t.indent||0)+1).join(" ");var f=t.indent?"\n":"";var h=l(o,u,r,e,t).trim();return"function ".concat(t.functionName||"main","(){").concat(c("return ".concat(h,";")),"}").concat(f)}t.toJscadScript=c;
/**
     * Exports a model in STL format - 2D to 3D.
     *
     * @param jscadCAG @jscad/csg CAG engine, see https://www.npmjs.com/package/@jscad/csg
     * @param stlSerializer @jscad/stl-serializer, see https://www.npmjs.com/package/@jscad/stl-serializer
     * @param modelToExport Model object to export.
     * @param options Optional options object.
     * @param options.byLayers Optional flag to separate chains by layers.
     * @param options.pointMatchingDistance Optional max distance to consider two points as the same.
     * @param options.maxArcFacet The maximum length between points on an arc or circle.
     * @param options.statusCallback Optional callback function to get the percentage complete.
     * @param options.extrude Optional default extrusion distance.
     * @param options.layerOptions Optional object map of options per layer, keyed by layer name. Each value for a key is an object with 'extrude' and 'z' properties.
     * @returns String in STL ASCII format.
     */function p(e,t,n,r){var a=r.statusCallback;r.statusCallback=i(a,0,50);var o=u(e,n,r);return t.serialize(o,{binary:false,statusCallback:i(a,50,50)})}t.toJscadSTL=p})(e.exporter||(e.exporter={}))})(c||(c={}));(function(e){(function(t){
/**
     * Injects drawing into a PDFKit document.
     *
     * @param doc PDFKit.PDFDocument object. See https://pdfkit.org/
     * @param modelToExport Model object to export.
     * @param options Export options object.
     * @returns String of PDF file contents.
     */
function n(n,r,a){if(r){var i={fontName:"Courier",fontSize:9,origin:[0,0],stroke:"#000"};e.extendObject(i,a);var o=1;var s=i.units||r.units;o=s?e.units.conversionScale(s,e.unitType.Inch):.01;o*=72;var u=e.model.scale(e.cloneObject(r),o);var l=e.measure.modelExtents(u);var c=-l.low[0];var p=[c,l.high[1]];p=e.point.add(p,i.origin);e.model.findChains(u,(function(r,a,o){function s(e){var r=t.pathToSVGPathData(e.pathContext,e.offset,p);n.path(r).stroke(i.stroke)}r.map((function(r){if(r.links.length>1){var a=t.chainToSVGPathData(r,p);n.path(a).stroke(i.stroke)}else{var o=r.links[0].walkedPath;if(o.pathContext.type===e.pathType.Circle){var u;e.path.moveTemporary([o.pathContext],[o.offset],(function(){u=e.path.mirror(o.pathContext,false,true)}));e.path.moveRelative(u,p);n.circle(u.origin[0],u.origin[1],o.pathContext.radius).stroke(i.stroke)}else s(o)}}));a.map(s)}),{byLayers:false});n.font(i.fontName).fontSize(i.fontSize);e.model.getAllCaptionsOffset(u).forEach((function(t){var r=e.angle.ofLineInDegrees(t.anchor);var a=e.path.mirror(t.anchor,false,true);e.path.moveRelative(a,p);var i=t.text;var o=[n.widthOfString(i)/2,n.heightOfString(i)/2];var s=e.point.middle(a);var u=e.point.subtract(s,o);n.rotate(-r,{origin:s});n.text(i,u[0],u[1]);n.rotate(r,{origin:s})}))}}t.toPDF=n})(e.exporter||(e.exporter={}))})(c||(c={}));(function(e){(function(t){var n={};n[e.pathType.Arc]=function(t,n,r,a,i){a.push("A");v(a,t.radius,n,i,e.angle.ofArcSpan(t)>180,r?t.startAngle>t.endAngle:t.startAngle<t.endAngle)};n[e.pathType.Line]=function(t,n,r,a,i){a.push("L",e.round(n[0],i),e.round(n[1],i))};n[e.pathType.BezierSeed]=function(e,t,n,r,a){h(r,e,a,n)};function r(t){return e.point.mirror(t,false,true)}function a(t){var n=e.angle.ofArcSpan(t);t.startAngle=e.angle.noRevolutions(t.startAngle);t.endAngle=t.startAngle+n}
/**
     * Convert a chain to SVG path data.
     *
     * @param c Chain to convert.
     * @param offset IPoint relative offset point.
     * @param accuracy Optional accuracy of SVG path data.
     * @param clockwise Optional flag to specify desired winding direction for nonzero fill rule.
     * @returns String of SVG path data.
     */function i(t,a,i,o){function s(t){return e.point.add(t,a)}if(o!==void 0){var u=e.measure.isChainClockwise(t);if(u!==null&&u!==o){t=e.cloneObject(t);e.chain.reverse(t)}}var l=t.links[0];var c=s(r(l.endPoints[l.reversed?1:0]));var p=["M",e.round(c[0],i),e.round(c[1],i)];for(var f=0;f<t.links.length;f++){var h=t.links[f];var v=h.walkedPath.pathContext;var d=n[v.type];if(d){var g;e.path.moveTemporary([v],[h.walkedPath.offset],(function(){g=e.path.mirror(v,false,true)}));e.path.moveRelative(g,a);d(g,s(r(h.endPoints[h.reversed?0:1])),h.reversed,p,i)}}t.endless&&p.push("Z");return p.join(" ")}t.chainToSVGPathData=i;function o(t,n,r){return["M",e.round(t[0],r),e.round(t[1],r)].concat(n)}var s={};s[e.pathType.Line]=function(t,n){return o(t.origin,e.point.rounded(t.end,n),n)};s[e.pathType.Circle]=function(e,t,n){return o(e.origin,f(e.radius,t,n),t)};s[e.pathType.Arc]=function(t,n){a(t);var r=e.point.fromArc(t);if(e.measure.isPointEqual(r[0],r[1]))return s[e.pathType.Circle](t,n);var i=["A"];v(i,t.radius,r[1],n,e.angle.ofArcSpan(t)>180,t.startAngle>t.endAngle);return o(r[0],i,n)};s[e.pathType.BezierSeed]=function(e,t){var n=[];h(n,e,t);return o(e.origin,n,t)};
/**
     * Export a path to SVG path data.
     *
     * @param pathToExport IPath to export.
     * @param pathOffset IPoint relative offset of the path object.
     * @param exportOffset IPoint relative offset point of the export.
     * @param accuracy Optional accuracy of SVG path data.
     * @param clockwiseCircle Optional flag to use clockwise winding for circles.
     * @returns String of SVG path data.
     */function u(t,n,r,a,i){var o=s[t.type];if(o){var u;e.path.moveTemporary([t],[n],(function(){u=e.path.mirror(t,false,true)}));e.path.moveRelative(u,r);var l=o(u,a,i);return l.join(" ")}return""}t.pathToSVGPathData=u;function l(t,n,r,a){var o={};r.unifyBeziers=true;e.model.findChains(t,(function(e,t,r){function s(e,t){var i=u(e.pathContext,e.offset,n,a,t);o[r].push(i)}o[r]=[];function l(e,t){e.forEach((function(e){if(e.links.length>1){var u=i(e,n,a,t);o[r].push(u)}else s(e.links[0].walkedPath,t);e.contains&&l(e.contains,!t)}))}l(e,true);t.forEach((function(e){return s(e)}))}),r);return o}function c(t){var n=[];for(var r=1;r<arguments.length;r++)n[r-1]=arguments[r];var a={fillRule:"evenodd"};if(typeof n[0]==="boolean"){a.byLayers=n[0];a.origin=n[1];a.accuracy=n[2]}else e.isObject(n[0])&&e.extendObject(a,n[0]);var i={byLayers:a.byLayers,contain:false};a.fillRule==="nonzero"&&(i.contain={alternateDirection:true});var o=e.measure.modelExtents(t);a.origin||(a.origin=[-o.low[0],o.high[1]]);var s=l(t,a.origin,i,a.accuracy);var u={};for(var c in s)u[c]=s[c].join(" ");return i.byLayers?u:u[""]}t.toSVGPathData=c;
/**
     * Renders an item in SVG markup.
     *
     * @param itemToExport Item to render: may be a path, an array of paths, or a model object.
     * @param options Rendering options object.
     * @param options.annotate Boolean to indicate that the id's of paths should be rendered as SVG text elements.
     * @param options.origin point object for the rendered reference origin.
     * @param options.scale Number to scale the SVG rendering.
     * @param options.stroke String color of the rendered paths.
     * @param options.strokeWidth String numeric width and optional units of the rendered paths.
     * @param options.units String of the unit system. May be omitted. See makerjs.unitType for possible values.
     * @param options.useSvgPathOnly Boolean to use SVG path elements instead of line, circle etc.
     * @returns String of XML / SVG content.
     */function p(n,i){function o(e,t,n){n===void 0&&(n=false);if(!n&&typeof t=="string"&&t.length>0){t in w||(w[t]=[]);w[t].push(e)}else P.push(e)}function s(e){var t=[];function n(e,n){n!==void 0&&t.push(e+":"+n)}n("stroke",e.stroke);n("stroke-width",e.strokeWidth);n("fill",e.fill);return t.join(";")}function u(t,n){n&&e.extendObject(t,{stroke:n.stroke,"stroke-width":n.strokeWidth,fill:n.fill,style:n.cssStyle||s(n),class:n.className})}function c(e){return m.layerOptions&&m.layerOptions[e]?m.layerOptions[e]:e in t.colors?{stroke:e}:void 0}function p(e,n,r,a,i){a===void 0&&(a=null);i===void 0&&(i=false);e!=="text"&&u(n,c(r));m.scalingStroke||(n["vector-effect"]="non-scaling-stroke");var s=new t.XmlTag(e,n);s.closingTags=m.closingTags;a&&(s.innerText=a);o(s.toString(),r,i)}function d(t){var n=r(t);return e.point.scale(n,m.scale)}function g(t,n){var r=e.path.mirror(t,false,true);return e.path.moveRelative(e.path.scale(r,m.scale),n)}var m={accuracy:.001,annotate:false,origin:null,scale:1,stroke:"#000",strokeLineCap:"round",strokeWidth:"0.25mm",fill:"none",fillRule:"evenodd",fontSize:"9pt",useSvgPathOnly:true,viewBox:true};e.extendObject(m,i);var y;var A=e.isModel(n);if(A){y=n;y.exporterOptions&&e.extendObject(m,y.exporterOptions.toSVG)}var P=[];var w={};if(A)y=n;else if(Array.isArray(n)){var T={};n.forEach((function(e,t){T[t]=e}));y={paths:T}}else e.isPath(n)&&(y={paths:{modelToMeasure:n}});var x=e.measure.modelExtents(y);var C=e.model.getAllCaptionsOffset(y);C.forEach((function(t){e.measure.increase(x,e.measure.pathExtents(t.anchor),true)}));if(!m.units){var b=t.tryGetModelUnits(n);b&&(m.units=b)}var k=t.svgUnit[m.units];k&&m.viewBox&&(m.scale*=k.scaleConversion);if(x&&!m.origin){var L=-x.low[0]*m.scale;m.origin=[L,x.high[1]*m.scale]}e.extendObject(i,m);var M={};if(x&&m.viewBox){var I=e.round(x.width*m.scale,m.accuracy);var S=e.round(x.height*m.scale,m.accuracy);var E=[0,0,I,S];var O=k?k.svgUnitType:"";M={width:I+O,height:S+O,viewBox:E.join(" ")}}M.xmlns="http://www.w3.org/2000/svg";var D=new t.XmlTag("svg",e.extendObject(M,m.svgAttrs));o(D.getOpeningTag(false));var z={id:"svgGroup","stroke-linecap":m.strokeLineCap,"fill-rule":m.fillRule,"font-size":m.fontSize};u(z,m);var R=new t.XmlTag("g",z);o(R.getOpeningTag(false));if(m.useSvgPathOnly){var B={byLayers:true};m.fillRule==="nonzero"&&(B.contain={alternateDirection:true});var N=l(y,m.origin,B,m.accuracy);for(var j in N){var _=N[j].join(" ");var q={d:_};j.length>0&&(q.id=j);p("path",q,j,null,true)}}else{function H(t,n,r){p("text",{id:t+"_text",x:e.round(n[0],m.accuracy),y:e.round(n[1],m.accuracy)},r,t)}function Y(t,n,r,a,i,o,s,u,l){p("path",{id:t,"data-route":o,d:["M",e.round(n,m.accuracy),e.round(r,m.accuracy)].concat(a).join(" ")},i);u&&H(t,s,i)}function $(e,t,n,r,a,i,o){var s=f(n,m.accuracy);Y(e,t[0],t[1],s,r,a,t,i,o)}var U={};U[e.pathType.Line]=function(t,n,r,a,i,o,s){var u=n.origin;var l=n.end;p("line",{id:t,class:a,"data-route":i,x1:e.round(u[0],m.accuracy),y1:e.round(u[1],m.accuracy),x2:e.round(l[0],m.accuracy),y2:e.round(l[1],m.accuracy)},r);o&&H(t,e.point.middle(n),r);s&&Q(s,r,n.origin,n.end,e.angle.ofLineInDegrees(n))};U[e.pathType.Circle]=function(t,n,r,a,i,o,s){var u=n.origin;p("circle",{id:t,class:a,"data-route":i,r:n.radius,cx:e.round(u[0],m.accuracy),cy:e.round(u[1],m.accuracy)},r);o&&H(t,u,r)};U[e.pathType.Arc]=function(t,n,r,i,o,s,u){a(n);var l=e.point.fromArc(n);if(e.measure.isPointEqual(l[0],l[1]))$(t,n.origin,n.radius,r,o,s,u);else{var c=["A"];v(c,n.radius,l[1],m.accuracy,e.angle.ofArcSpan(n)>180,n.startAngle>n.endAngle);Y(t,l[0][0],l[0][1],c,r,o,e.point.middle(n),s,u);u&&Q(u,r,l[1],l[0],e.angle.noRevolutions(n.startAngle-90))}};U[e.pathType.BezierSeed]=function(t,n,r,a,i,o,s){var u=[];h(u,n,m.accuracy);Y(t,n.origin[0],n.origin[1],u,r,i,e.point.middle(n),o,s)};function Q(t,n,r,a,i){var o="flow";U[e.pathType.Circle]("",new e.paths.Circle(r,t.size/2),n,o,null,false,null);var s=[-1*t.size,t.size/2];var u=[s,e.point.mirror(s,false,true)].map((function(t){return new e.paths.Line(e.point.add(e.point.rotate(t,i),a),a)}));u.forEach((function(t){return U[e.pathType.Line]("",t,n,o,null,false,null)}))}function Z(e,t){K.attrs={id:e};o(K.getOpeningTag(false),t.layer)}function ee(e){o(K.getClosingTag(),e.layer)}var K=new t.XmlTag("g");var X={beforeChildWalk:function(e){Z(e.childId,e.childModel);return true},onPath:function(t){var n=U[t.pathContext.type];if(n){var r=e.point.add(d(t.offset),m.origin);n(t.pathId,g(t.pathContext,r),t.layer,null,t.route,m.annotate,m.flow)}},afterChildWalk:function(e){ee(e.childModel)}};Z("0",y);e.model.walk(y,X);for(var G in w){var V=new t.XmlTag("g",{id:G});u(V.attrs,c(G));for(var J=0;J<w[G].length;J++)V.innerText+=w[G][J];V.innerTextEscaped=true;o(V.toString())}ee(y)}var F=C.map((function(n){var r=g(n.anchor,m.origin);var a=e.point.rounded(e.point.middle(r),m.accuracy);var i=new t.XmlTag("text",{"alignment-baseline":"middle","text-anchor":"middle",transform:"rotate(".concat(e.angle.ofLineInDegrees(r),",").concat(a[0],",").concat(a[1],")"),x:a[0],y:a[1]});u(i.attrs,c(n.layer));i.innerText=n.text;return i.toString()}));if(F.length){var W=new t.XmlTag("g",{id:"captions"});u(W.attrs,c(W.attrs.id));W.innerText=F.join("");W.innerTextEscaped=true;o(W.toString())}o(R.getClosingTag());o(D.getClosingTag());return P.join("")}t.toSVG=p;function f(t,n,r){var a=e.round(t,n);var i=["m",-a,0];function o(e){i.push("a");v(i,a,[2*a*e,0],n,false,!r)}o(1);o(-1);i.push("z");return i}function h(t,n,r,a){if(n.controls.length===1)t.push("Q",e.round(n.controls[0][0],r),e.round(n.controls[0][1],r));else{var i=a?[n.controls[1],n.controls[0]]:n.controls;t.push("C",e.round(i[0][0],r),e.round(i[0][1],r),e.round(i[1][0],r),e.round(i[1][1],r))}var o=a?n.origin:n.end;t.push(e.round(o[0],r),e.round(o[1],r))}function v(t,n,r,a,i,o){var s=e.round(n,a);var u=r;t.push(s,s);t.push(0);t.push(i?1:0);t.push(o?0:1);t.push(e.round(u[0],a),e.round(u[1],a))}t.svgUnit={};t.svgUnit[e.unitType.Inch]={svgUnitType:"in",scaleConversion:1};t.svgUnit[e.unitType.Millimeter]={svgUnitType:"mm",scaleConversion:1};t.svgUnit[e.unitType.Centimeter]={svgUnitType:"cm",scaleConversion:1};t.svgUnit[e.unitType.Foot]={svgUnitType:"in",scaleConversion:12};t.svgUnit[e.unitType.Meter]={svgUnitType:"cm",scaleConversion:100}})(e.exporter||(e.exporter={}))})(c||(c={}));(function(e){(function(t){
/**
     * Create a model from SVG path data.
     *
     * @param pathData SVG path data.
     * @param options ISVGImportOptions object.
     * @param options.bezierAccuracy Optional accuracy of Bezier curves.
     * @returns An IModel object.
     */
function n(n,r){r===void 0&&(r={});var a={};function i(e){a.paths||(a.paths={});a.paths["p_"+ ++f]=e}function o(e){a.models||(a.models={});a.models["p_"+ ++f]=e}function s(t,n,r){n===void 0&&(n=0);r===void 0&&(r=t.from);n<0&&(n+=t.data.length);var a=e.point.mirror([t.data[0+n],t.data[1+n]],false,true);return t.absolute?a:e.point.add(a,r)}function u(t,n){e.measure.isPointEqual(t.from,n)||i(new e.paths.Line(t.from,n));return n}var l={};l.M=function(e){c=s(e);if(e.data.length>2){e.from=c;for(var t=2;t<e.data.length;t+=2)e.from=u(e,s(e,t));return e.from}return c};l.Z=function(e){return u(e,c)};l.H=function(t){var n=e.point.clone(t.from);t.absolute?n[0]=t.data[0]:n[0]+=t.data[0];return u(t,n)};l.V=function(t){var n=e.point.clone(t.from);t.absolute?n[1]=-t.data[0]:n[1]-=t.data[0];return u(t,n)};l.L=function(e){var t;for(var n=0;n<e.data.length;n+=2){t=s(e,n);e.from=u(e,t)}return e.from};l.A=function(t){var n;var a;var u;var l;var c;var p;var f;var h;var v;var d;var g;for(var m=0;m<t.data.length;m+=7){n=t.data[0+m];a=t.data[1+m];u=t.data[2+m];l=t.data[3+m]===1;c=t.data[4+m]===1;p=s(t,5+m);f=n!==a;h=new e.paths.Line(t.from,e.point.rotate(p,u,t.from));f&&(h=e.path.distort(h,1,n/a));v=new e.paths.Arc(h.origin,h.end,n,l,c);if(f){if(n<v.radius){d=v.radius/n;n*=d;a*=d}g=new e.models.EllipticArc(v,1,a/n,r.bezierAccuracy);e.model.rotate(g,-u,t.from);o(g)}else{e.path.rotate(v,-u,t.from);i(v)}t.from=p}return p};l.C=function(t){var n;var a;var i=t.from;var u;for(var l=0;l<t.data.length;l+=6){t.from=i;n=s(t,0+l,i);a=s(t,2+l,i);u=s(t,4+l,i);o(new e.models.BezierCurve(i,n,a,u,r.bezierAccuracy));i=u}return u};l.S=function(t){var n;var a;var i;var u=t.from;var l;a=t.prev.command==="C"||t.prev.command==="S"?s(t.prev,-4):t.from;for(var c=0;c<t.data.length;c+=4){t.from=u;n=e.point.rotate(a,180,u);i=s(t,0+c);l=s(t,2+c);o(new e.models.BezierCurve(u,n,i,l,r.bezierAccuracy));u=l;a=i}return l};l.Q=function(t){var n;var a=t.from;var i;for(var u=0;u<t.data.length;u+=4){t.from=a;n=s(t,0+u);i=s(t,2+u);o(new e.models.BezierCurve(a,n,i,r.bezierAccuracy));a=i}return i};l.T=function(t){var n;var a;var i;if(t.prev.command==="Q"){a=s(t.prev,-4);n=e.point.rotate(a,180,t.from)}else if(t.prev.command==="T"){t.prev.absolute=true;n=s(t.prev,-2)}else n=t.from;for(var u=0;u<t.data.length;u+=2){i=s(t,0+u);o(new e.models.BezierCurve(t.from,n,i,r.bezierAccuracy));t.from=i;n=e.point.rotate(n,180,t.from)}var l=e.point.mirror(n,false,true);t.data.push.apply(t.data,l);return i};var c=[0,0];var p=[0,0];var f=0;var h;var v=/([achlmqstvz])([0-9e\.,\+-\s]*)/gi;var d;while((d=v.exec(n))!==null){d.index===v.lastIndex&&v.lastIndex++;var g=d[1];var m=d[2];var y={command:g.toUpperCase(),data:[],from:p,prev:h};g===y.command&&(y.absolute=true);y.data=t.parseNumericList(m);var A=l[y.command];A&&(p=A(y));h=y}return a}t.fromSVGPathData=n})(e.importer||(e.importer={}))})(c||(c={}));(function(e){(function(t){function n(t,n){var r=new e.measure.Atlas(t);var a=e.measure.modelExtents(t,r);var i=a.high[1];var o=[];var s={};var u={beforeChildWalk:function(t){var u=t.childModel;var l=r.modelMap[t.routeKey];if(l){var c=e.measure.augment(l);e.model.originate(u,[c.center[0],i*n]);var p=u.origin[0]-a.low[0];s[t.childId]=p;var f=p/a.width;o.push({childId:t.childId,xRatio:f});return false}}};e.model.walk(t,u);o.sort((function(e,t){return e.xRatio-t.xRatio}));var l=o[0];var c=o[o.length-1];if(o.length>1){var p=l.xRatio;var f=c.xRatio;var h=f-p;o.forEach((function(e){return e.xRatio=(e.xRatio-p)/h}))}return{cpa:o,firstX:s[l.childId],lastX:a.width-s[c.childId]}}function r(t,n,r){n.forEach((function(n){var a=t.models[n.childId];a.origin=n.origin;r&&e.model.rotate(a,n.angle,n.origin)}))}var a={};a[e.pathType.Arc]=function(t,n,r){var a=e.angle.ofArcSpan(t);r.forEach((function(e){return e.angle=n?t.endAngle-e.xRatio*a-90:t.startAngle+e.xRatio*a+90}))};a[e.pathType.Line]=function(t,n,r){var a=e.angle.ofLineInDegrees(t);r.forEach((function(e){return e.angle=a}))};
/**
     * Layout the children of a model along a path.
     * The x-position of each child will be projected onto the path so that the proportion between children is maintained.
     * Each child will be rotated such that it will be perpendicular to the path at the child's x-center.
     *
     * @param parentModel The model containing children to lay out.
     * @param onPath The path on which to lay out.
     * @param baseline Numeric percentage value of vertical displacement from the path. Default is zero.
     * @param reversed Flag to travel along the path in reverse. Default is false.
     * @param contain Flag to contain the children layout within the length of the path. Default is false.
     * @param rotate Flag to rotate the child to perpendicular. Default is true.
     * @returns The parentModel, for cascading.
     */function i(t,i,o,s,u,l){o===void 0&&(o=0);s===void 0&&(s=false);u===void 0&&(u=false);l===void 0&&(l=true);var c=n(t,o);var p=c.cpa;var f=i;if(u&&p.length>1){var h=e.measure.pathLength(i);if(c.firstX+c.lastX<h){f=e.path.clone(i);e.path.alterLength(f,-c.firstX,true);e.path.alterLength(f,-c.lastX)}}p.forEach((function(t){return t.origin=e.point.middle(f,s?1-t.xRatio:t.xRatio)}));var v=a[f.type];v&&v(f,s,p);r(t,p,l);return t}t.childrenOnPath=i;function o(t,n){var r=new e.paths.Arc([0,0],0,0,0);return t.map((function(a,i){var o;if(i===0)o=e.angle.ofPointInDegrees(a,t[i+1])+90;else if(i===t.length-1)o=e.angle.ofPointInDegrees(t[i-1],a)+90;else{r.origin=a;r.startAngle=e.angle.ofPointInDegrees(a,t[i+1]);r.endAngle=e.angle.ofPointInDegrees(a,t[i-1]);o=e.angle.ofArcMiddle(r)}return o+n}))}
/**
     * Layout the children of a model along a chain.
     * The x-position of each child will be projected onto the chain so that the proportion between children is maintained.
     * The projected positions of the children will become an array of points that approximate the chain.
     * Each child will be rotated such that it will be mitered according to the vertex angles formed by this series of points.
     *
     * @param parentModel The model containing children to lay out.
     * @param onChain The chain on which to lay out.
     * @param baseline Numeric percentage value of vertical displacement from the chain. Default is zero.
     * @param reversed Flag to travel along the chain in reverse. Default is false.
     * @param contain Flag to contain the children layout within the length of the chain. Default is false.
     * @param rotate Flag to rotate the child to mitered angle. Default is true.
     * @returns The parentModel, for cascading.
     */function s(t,a,i,s,u,l){i===void 0&&(i=0);s===void 0&&(s=false);u===void 0&&(u=false);l===void 0&&(l=true);var c=n(t,i);var p=c.cpa;var f=a.pathLength;var h;if(p.length>1){u&&(f-=c.firstX+c.lastX);var v=p.map((function(e){return(s?1-e.xRatio:e.xRatio)*f}));var d;s&&v.reverse();d=v.map((function(e,t){return Math.abs(e-(t==0?0:v[t-1]))}));u?d[0]+=s?c.lastX:c.firstX:d.shift();h=e.chain.toPoints(a,d);if(h.length<p.length){var g=a.links[a.links.length-1];h.push(g.endPoints[g.reversed?0:1])}u&&h.shift()}else{h=e.chain.toPoints(a,.5*f);h.length=2;h.push(a.links[a.links.length-1].endPoints[a.links[a.links.length-1].reversed?0:1])}s&&h.reverse();var m=o(h,-90);if(p.length>1)p.forEach((function(e,t){e.angle=m[t];e.origin=h[t]}));else{p[0].angle=m[1];p[0].origin=h[1]}r(t,p,l);return t}t.childrenOnChain=s;
/**
     * Layout clones in a radial format.
     *
     * Example:
     * ```
     * //daisy petals
     * var makerjs = require('makerjs');
     *
     * var belt = new makerjs.models.Belt(5, 50, 20);
     *
     * makerjs.model.move(belt, [25, 0]);
     *
     * var petals = makerjs.layout.cloneToRadial(belt, 8, 45);
     *
     * document.write(makerjs.exporter.toSVG(petals));
     * ```
     *
     * @param itemToClone: Either a model or a path object.
     * @param count Number of clones in the radial result.
     * @param angleInDegrees angle of rotation between clones..
     * @returns A new model with clones in a radial format.
     */function u(t,n,r,a){var i={};var o;var s;if(e.isModel(t)){o=i.models={};s=e.model.rotate}else{o=i.paths={};s=e.path.rotate}for(var u=0;u<n;u++)o[u]=s(e.cloneObject(t),u*r,a);return i}t.cloneToRadial=u;function l(t,n,r,a){var i={};var o;var s;var u;if(e.isModel(n)){s=e.measure.modelExtents;o=i.models={};u=e.model.move}else{s=e.measure.pathExtents;o=i.paths={};u=e.path.move}var l=s(n);var c=l.high[t]-l.low[t];for(var p=0;p<r;p++){var f=[0,0];f[t]=p*(c+a);o[p]=u(e.cloneObject(n),f)}return i}
/**
     * Layout clones in a column format.
     *
     * Example:
     * ```
     * //Grooves for a finger joint
     * var m = require('makerjs');
     *
     * var dogbone = new m.models.Dogbone(50, 20, 2, -1, false);
     *
     * var grooves = m.layout.cloneToColumn(dogbone, 5, 20);
     *
     * document.write(m.exporter.toSVG(grooves));
     * ```
     *
     * @param itemToClone: Either a model or a path object.
     * @param count Number of clones in the column.
     * @param margin Optional distance between each clone.
     * @returns A new model with clones in a column.
     */function c(e,t,n){n===void 0&&(n=0);return l(1,e,t,n)}t.cloneToColumn=c;
/**
     * Layout clones in a row format.
     *
     * Example:
     * ```
     * //Tongue and grooves for a box joint
     * var m = require('makerjs');
     * var tongueWidth = 60;
     * var grooveWidth = 50;
     * var grooveDepth = 30;
     * var groove = new m.models.Dogbone(grooveWidth, grooveDepth, 5, 0, true);
     *
     * groove.paths['leftTongue'] = new m.paths.Line([-tongueWidth / 2, 0], [0, 0]);
     * groove.paths['rightTongue'] = new m.paths.Line([grooveWidth, 0], [grooveWidth + tongueWidth / 2, 0]);
     *
     * var tongueAndGrooves = m.layout.cloneToRow(groove, 3);
     *
     * document.write(m.exporter.toSVG(tongueAndGrooves));
     * ```
     *
     * @param itemToClone: Either a model or a path object.
     * @param count Number of clones in the row.
     * @param margin Optional distance between each clone.
     * @returns A new model with clones in a row.
     */function p(e,t,n){n===void 0&&(n=0);return l(0,e,t,n)}t.cloneToRow=p;
/**
     * Layout clones in a grid format.
     *
     * Example:
     * ```
     * //Grid of squares
     * var m = require('makerjs');
     * var square = new m.models.Square(43);
     * var grid = m.layout.cloneToGrid(square, 5, 5, 7);
     * document.write(m.exporter.toSVG(grid));
     * ```
     *
     * @param itemToClone: Either a model or a path object.
     * @param xCount Number of columns in the grid.
     * @param yCount Number of rows in the grid.
     * @param margin Optional numeric distance between each clone. Can also be a 2 dimensional array of numbers, to specify distances in x and y dimensions.
     * @returns A new model with clones in a grid layout.
     */function f(e,t,n,r){var a=h(r);return c(p(e,t,a[0]),n,a[1])}t.cloneToGrid=f;function h(e){return Array.isArray(e)?e:[e,e]}function v(t,n,r,a){var i;i=e.isModel(t)?t:{paths:{0:t}};var o=a(i);var s={models:{}};for(var u=0;u<r;u++){var l=u%2;s.models[u]=e.model.move(p(t,n+l,o.xMargin),[l*o.x,u*o.y])}return s}
/**
     * Layout clones in a brick format. Alternating rows will have an additional item in each row.
     *
     * Examples:
     * ```
     * //Brick wall
     * var m = require('makerjs');
     * var brick = new m.models.RoundRectangle(50, 30, 4);
     * var wall = m.layout.cloneToBrick(brick, 8, 6, 3);
     * document.write(m.exporter.toSVG(wall));
     * ```
     *
     * ```
     * //Fish scales
     * var m = require('makerjs');
     * var arc = new m.paths.Arc([0, 0], 50, 20, 160);
     * var scales = m.layout.cloneToBrick(arc, 8, 20);
     * document.write(m.exporter.toSVG(scales));
     * ```
     *
     * @param itemToClone: Either a model or a path object.
     * @param xCount Number of columns in the brick grid.
     * @param yCount Number of rows in the brick grid.
     * @param margin Optional numeric distance between each clone. Can also be a 2 dimensional array of numbers, to specify distances in x and y dimensions.
     * @returns A new model with clones in a brick layout.
     */function d(t,n,r,a){var i=h(a);function o(t){var n=e.measure.modelExtents(t);var r=i[0]||0;var a=i[1]||0;return{x:(n.width+r)/-2,y:n.height+a,xMargin:r}}return v(t,n,r,o)}t.cloneToBrick=d;
/**
     * Layout clones in a honeycomb format. Alternating rows will have an additional item in each row.
     *
     * Examples:
     * ```
     * //Honeycomb
     * var m = require('makerjs');
     * var hex = new m.models.Polygon(6, 50, 30);
     * var pattern = m.layout.cloneToHoneycomb(hex, 8, 9, 10);
     * document.write(m.exporter.toSVG(pattern));
     * ```
     *
     * @param itemToClone: Either a model or a path object.
     * @param xCount Number of columns in the honeycomb grid.
     * @param yCount Number of rows in the honeycomb grid.
     * @param margin Optional distance between each clone.
     * @returns A new model with clones in a honeycomb layout.
     */function g(t,n,r,a){a===void 0&&(a=0);function i(t){var n=e.measure.boundingHexagon(t);var r=2*e.solvers.equilateralAltitude(n.radius);var i=r+a;return{x:i/-2,y:e.solvers.equilateralAltitude(i),xMargin:a}}return v(t,n,r,i)}t.cloneToHoneycomb=g})(e.layout||(e.layout={}))})(c||(c={}));(function(e){(function(t){var n=false;function r(){if(!n)try{p.prototype;n=true}catch(e){throw"Bezier library not found. If you are using Node, try running 'npm install' or if you are in the browser, download http://pomax.github.io/bezierjs/bezier.js to your website and add a script tag."}}var a;function i(e){var t=[e.origin];t.push.apply(t,e.controls);t.push(e.end);var n=t.map((function(e){var t={x:e[0],y:e[1]};return t}));if(a)p.apply(a,n);else{r();a=new p(n)}return a}function o(e,t){var n=e.points.map(c);var r=new y(n);t&&(r.parentRange=t);return r}function s(e){var t=[];t.push.apply(t,e.origin);t.push.apply(t,e.controls[0]);e.controls.length>1&&t.push.apply(t,e.controls[1]);t.push.apply(t,e.end);r();return new p(t)}function l(t){var n=t.extrema().values.map((function(t){return e.round(t)})).filter((function(e,t,n){return n.indexOf(e)===t})).sort();if(n.length===0)return[0,1];n[0]!==0&&n.unshift(0);n[n.length-1]!==1&&n.push(1);return n}function c(e){return[e.x,e.y]}var f=function(){function t(t,n,r){(this||u).t=n;(this||u).point=e.point.add(c(t.get(n)),r)}return t}();function h(t,n,r,a,i){var o=r-n;function s(r){var s=n+o*r;var u=c(t.get(s));var l=e.point.middle(a,i?1-r:r);return e.measure.pointDistance(l,u)}return s(.25)+s(.75)}function v(t,n,r,a){var i,o;var s=new f(t,n);var u=new f(t,r);var l=u;var p=s;var v=0;var d=l;var g;while(v<100){var m=c(t.get((s.t+d.t)/2));try{i=new e.paths.Arc(s.point,m,d.point)}catch(e){if(o)return o;break}g===void 0&&(g=e.measure.isPointEqual(s.point,e.point.fromAngleOnCircle(i.endAngle,i)));var y=h(t,n,d.t,i,g);if(y<=a){i.bezierData={startT:n,endT:d.t};p=d;o=i}else l=d;if(p.t===l.t||o&&o!==i&&e.angle.ofArcSpan(i)-e.angle.ofArcSpan(o)<.5)return o;v++;d=new f(t,(p.t+l.t)/2)}var A=new e.paths.Line(s.point,d.point);A.bezierData={startT:n,endT:d.t};return A}function d(t,n,r,a,i,o){var s=0;var u;while(a<i){u=v(n,a,i,r);a=u.bezierData.endT;var l=e.measure.pathLength(u);if(!(l<1e-4)){t.paths[u.type+"_"+(o+s)]=u;s++}}return s}function g(t,n,r,a,o){var s=i(t.seed);var u=[n.bezierData.startT,n.bezierData.endT].map((function(e){return new f(s,e,a)}));var l=r.slice();var c=l.map((function(t){return e.measure.pointDistance(t,u[0].point)}));c[0]>c[1]&&l.reverse();for(var p=2;p--;)if(!e.measure.isPointEqual(l[p],u[p].point,o))return null;return n.bezierData}function m(t,n,r,a,i){var o=[n.links[0],n.links[n.links.length-1]];if(o[0].walkedPath.pathContext.bezierData.startT>o[1].walkedPath.pathContext.bezierData.startT){e.chain.reverse(n);o.reverse()}var s=o.map((function(e){return g(t,e.walkedPath.pathContext,e.endPoints,e.walkedPath.offset,i)}));var u={startT:s[0]?s[0].startT:null,endT:s[1]?s[1].endT:null};if(u.startT!==null&&u.endT!==null)return u;if(n.links.length>2){if(u.startT===null){a(n.links[0].walkedPath.pathContext,r,true);u.startT=n.links[1].walkedPath.pathContext.bezierData.startT}if(u.endT===null){a(n.links[n.links.length-1].walkedPath.pathContext,r,true);u.endT=n.links[n.links.length-2].walkedPath.pathContext.bezierData.endT}return u}return null}var y=function(){function t(){var t=[];for(var n=0;n<arguments.length;n++)t[n]=arguments[n];(this||u).type=e.pathType.BezierSeed;switch(t.length){case 1:var r=t[0];(this||u).origin=r[0];if(r.length===3){(this||u).controls=[r[1]];(this||u).end=r[2]}else if(r.length===4){(this||u).controls=[r[1],r[2]];(this||u).end=r[3]}else(this||u).end=r[1];break;case 3:Array.isArray(t[1])?(this||u).controls=t[1]:(this||u).controls=[t[1]];(this||u).end=t[2];break;case 4:(this||u).controls=[t[1],t[2]];(this||u).end=t[3];break}}return t}();var A=function(){function t(){var n=[];for(var r=0;r<arguments.length;r++)n[r]=arguments[r];(this||u).type=t.typeName;var a=Array.isArray(n[0]);switch(n.length){case 2:if(!a){(this||u).seed=n[0];(this||u).accuracy=n[1];break}(this||u).accuracy=n[1];case 1:if(a){var i=n[0];(this||u).seed=new y(i)}else(this||u).seed=n[0];break;default:switch(n.length){case 4:if(e.isPoint(n[3])){(this||u).seed=new y(n);break}(this||u).accuracy=n[3];case 3:a&&((this||u).seed=new y(n.slice(0,3)));break;case 5:(this||u).accuracy=n[4];(this||u).seed=new y(n.slice(0,4));break}break}(this||u).paths={};if(e.measure.isBezierSeedLinear((this||u).seed)){var o=new e.paths.Line(e.point.clone((this||u).seed.origin),e.point.clone((this||u).seed.end));o.bezierData={startT:0,endT:1};(this||u).paths={0:o}}else{var c=s((this||u).seed);var p=l(c);(this||u).paths={};if(!(this||u).accuracy){var f=c.length();(this||u).accuracy=f/100}var h=0;for(var v=1;v<p.length;v++){var g=p[v]-p[v-1];h+=d(this||u,c,(this||u).accuracy*g,p[v-1],p[v],h)}}}t.getBezierSeeds=function(t,n){n===void 0&&(n={});n.shallow=true;n.unifyBeziers=false;var r={};var a=function(t,n,a){a===void 0&&(a=false);r[n]||(r[n]=[]);r[n].push(a?e.path.clone(t):t)};e.model.findChains(t,(function(r,s,u){r.forEach((function(e){var r=m(t,e,u,a,n.pointMatchingDistance);if(r){var s=i(t.seed);var l=s.split(r.startT,r.endT);a(o(l),u)}else e.links.forEach((function(e){return a(e.walkedPath.pathContext,u,true)}))}));s.forEach((function(r){if(r.pathContext.type===e.pathType.Line)return a(r.pathContext,u,true);var s=g(t,r.pathContext,e.point.fromPathEnds(r.pathContext),r.offset,n.pointMatchingDistance);if(s){var l=i(t.seed);var c=l.split(s.startT,s.endT);a(o(c),u)}else a(r.pathContext,u,true)}))}),n);return n.byLayers?r:r[""]};t.computeLength=function(e){var t=s(e);return t.length()};t.computePoint=function(e,t){var n=i(e);var r=n.compute(t);return c(r)};t.typeName="BezierCurve";return t}();t.BezierCurve=A;A.metaParameters=[{title:"points",type:"select",value:[[[100,0],[-80,-60],[100,220],[100,60]],[[0,0],[100,0],[100,100]],[[0,0],[20,0],[80,100],[100,100]]]}]})(e.models||(e.models={}))})(c||(c={}));(function(e){(function(t){var n=45;function r(e){return Math.tan(e/4)/3*4}function a(t){var n=e.angle.ofArcSpan(t);var a=r(e.angle.toRadians(n));var i=[t.radius,t.radius*a];var o=e.point.rotate(e.point.mirror(i,false,true),n,[0,0]);return[i,o].map((function(n){return e.point.add(t.origin,e.point.rotate(n,t.startAngle,[0,0]))}))}function i(t){var n=e.angle.ofArcSpan(t);if(n<=90){var r=e.point.fromPathEnds(t);var i=a(t);return{type:e.pathType.BezierSeed,origin:r[0],controls:i,end:r[1]}}return null}var o=function(){function r(){var r=[];for(var a=0;a<arguments.length;a++)r[a]=arguments[a];var o=this||u;(this||u).models={};var s=360/n;var l;var c=e.isPoint(r[0]);var p=function(n){switch(n){case 2:c&&(o.origin=r[0]);break;case 3:o.origin=r[0];break;case 4:o.origin=[r[0],r[1]];break}var a=360/s;var u=new e.paths.Arc([0,0],1,0,a);for(var p=0;p<s;p++){var f=i(u);switch(n){case 1:f=e.path.scale(f,r[0]);break;case 2:f=c?e.path.scale(f,r[1]):e.path.distort(f,r[0],r[1]);break;case 3:f=e.path.distort(f,r[1],r[2]);break;case 4:f=e.path.distort(f,r[2],r[3]);break}o.models["Curve_"+(1+p)]=new t.BezierCurve(f,l);u.startAngle+=a;u.endAngle+=a}};switch(r.length){case 2:p(2);break;case 3:if(c)p(3);else{l=r[2];p(2)}break;case 4:if(c){l=r[3];p(3)}else p(4);break;case 5:l=r[4];p(4);break}}return r}();t.Ellipse=o;o.metaParameters=[{title:"radiusX",type:"range",min:1,max:50,value:50},{title:"radiusY",type:"range",min:1,max:50,value:25}];var s=function(){function r(){var r=[];for(var a=0;a<arguments.length;a++)r[a]=arguments[a];(this||u).models={};var o;var s;var l;var c;if(e.isPathArc(r[0])){o=r[0];l=r[1];c=r[2];s=r[3]}else{o=new e.paths.Arc([0,0],1,r[0],r[1]);l=r[2];c=r[3];s=r[4]}var p=e.angle.ofArcSpan(o);var f=Math.ceil(p/n);var h=p/f;var v=e.path.clone(o);for(var d=0;d<f;d++){v.startAngle=o.startAngle+d*h;v.endAngle=v.startAngle+h;var g=i(v);g=e.path.distort(g,l,c);(this||u).models["Curve_"+(1+d)]=new t.BezierCurve(g,s)}}return r}();t.EllipticArc=s;s.metaParameters=[{title:"startAngle",type:"range",min:0,max:90,value:0},{title:"endAngle",type:"range",min:90,max:360,value:180},{title:"radiusX",type:"range",min:1,max:50,value:50},{title:"radiusY",type:"range",min:1,max:50,value:25}]})(e.models||(e.models={}))})(c||(c={}));(function(e){(function(t){function n(t){var n;if(Array.isArray(t)){if(e.isPoint(t[0]))return t;n=t}else n=e.importer.parseNumericList(t);var r=[];for(var a=0;a<n.length;a+=2)r.push([n[a],n[a+1]]);return r}var r=function(){function t(){var t=[];for(var r=0;r<arguments.length;r++)t[r]=arguments[r];var a=this||u;(this||u).paths={};var i;var o;switch(t.length){case 1:i=true;o=n(t[0]);break;case 2:i=t[0];o=n(t[1]);break}var s=function(t,n,r){r===void 0&&(r=false);r&&e.measure.pointDistance(o[t],o[n])==0||(a.paths["ShapeLine"+l]=new e.paths.Line(o[t],o[n]))};for(var l=1;l<o.length;l++)s(l-1,l);i&&o.length>2&&s(o.length-1,0,true)}return t}();t.ConnectTheDots=r;r.metaParameters=[{title:"closed",type:"bool",value:true},{title:"points",type:"select",value:[[[0,0],[40,40],[60,20],[100,100],[60,60],[40,80]],[[0,0],[100,0],[50,87]],[-10,0,10,0,0,20],"-10 0 10 0 0 20"]}]})(e.models||(e.models={}))})(c||(c={}));(function(e){(function(t){var n=function(){function n(e,r,a,i){(this||u).paths={};(this||u).paths=new t.ConnectTheDots(true,n.getPoints(e,r,a,i)).paths}n.circumscribedRadius=function(e,t){return e/Math.cos(t/2)};n.getPoints=function(t,r,a,i){a===void 0&&(a=0);i===void 0&&(i=false);var o=[];var s=e.angle.toRadians(a);var u=2*Math.PI/t;i&&(r=n.circumscribedRadius(r,u));for(var l=0;l<t;l++)o.push(e.point.fromPolar(u*l+s,r));return o};return n}();t.Polygon=n;n.metaParameters=[{title:"number of sides",type:"range",min:3,max:24,value:6},{title:"radius",type:"range",min:1,max:100,value:50},{title:"offset angle",type:"range",min:0,max:180,value:0},{title:"radius on flats (vs radius on vertexes)",type:"bool",value:false}]})(e.models||(e.models={}))})(c||(c={}));(function(e){(function(t){var n=function(){
/**
       * Create an array of circles of the same radius from an array of center points.
       *
       * Example:
       * ```
       * //Create some holes from an array of points
       * var makerjs = require('makerjs');
       * var model = new makerjs.models.Holes(10, [[0, 0],[50, 0],[25, 40]]);
       * var svg = makerjs.exporter.toSVG(model);
       * document.write(svg);
       * ```
       *
       * @param holeRadius Hole radius.
       * @param points Array of points for origin of each hole.
       * @param ids Optional array of corresponding path ids for the holes.
       */
function t(t,n,r){(this||u).paths={};for(var a=0;a<n.length;a++){var i=r?r[a]:a.toString();(this||u).paths[i]=new e.paths.Circle(n[a],t)}}return t}();t.Holes=n;n.metaParameters=[{title:"holeRadius",type:"range",min:.1,max:10,step:.1,value:1},{title:"points",type:"select",value:[[[0,0],[10,10],[20,20],[30,30],[40,40],[50,50],[60,60],[70,70],[80,80]],[[0,0],[0,25],[0,50],[0,75],[0,100],[25,50],[50,50],[75,50],[100,100],[100,75],[100,50],[100,25],[100,0]]]}]})(e.models||(e.models={}))})(c||(c={}));(function(e){(function(e){var t=function(){function t(t,n,r,a){a===void 0&&(a=0);(this||u).paths={};var i=e.Polygon.getPoints(r,t,a);var o=i.map((function(e,t){return"bolt "+t}));(this||u).paths=new e.Holes(n,i,o).paths}return t}();e.BoltCircle=t;t.metaParameters=[{title:"bolt circle radius",type:"range",min:1,max:100,value:50},{title:"hole radius",type:"range",min:1,max:50,value:5},{title:"bolt count",type:"range",min:3,max:24,value:12},{title:"offset angle",type:"range",min:0,max:180,value:0}]})(e.models||(e.models={}))})(c||(c={}));(function(e){(function(e){var t=function(){function t(t,n,r){(this||u).paths={};var a=[[0,0],[t,0],[t,n],[0,n]];var i=["BottomLeft_bolt","BottomRight_bolt","TopRight_bolt","TopLeft_bolt"];(this||u).paths=new e.Holes(r,a,i).paths}return t}();e.BoltRectangle=t;t.metaParameters=[{title:"width",type:"range",min:1,max:100,value:100},{title:"height",type:"range",min:1,max:100,value:50},{title:"hole radius",type:"range",min:1,max:50,value:5}]})(e.models||(e.models={}))})(c||(c={}));(function(e){(function(t){var n=function(){
/**
       * Create a dogbone from width, height, corner radius, style, and bottomless flag.
       *
       * Example:
       * ```
       * var d = new makerjs.models.Dogbone(50, 100, 5);
       * ```
       *
       * @param width Width of the rectangle.
       * @param height Height of the rectangle.
       * @param radius Corner radius.
       * @param style Optional corner style: 0 (default) for dogbone, 1 for vertical, -1 for horizontal.
       * @param bottomless Optional flag to omit the bottom line and bottom corners (default false).
       */
function t(t,n,r,a,i){a===void 0&&(a=0);i===void 0&&(i=false);(this||u).paths={};var o=Math.min(n,t)/2;var s;switch(a){case-1:case 1:s=o/2;break;case 0:default:s=o*Math.SQRT2/2;break}r=Math.min(r,s);var l;var c;var p;var f;var h;switch(a){case-1:l=0;c=r;p=0;f=r*2;h=[180,0,0,180];break;case 1:l=r;c=0;p=r*2;f=0;h=[270,270,90,90];break;case 0:default:l=c=r/Math.SQRT2;p=f=l*2;h=[225,315,45,135];break}if(i){(this||u).paths.Left=new e.paths.Line([0,0],[0,n-f]);(this||u).paths.Right=new e.paths.Line([t,0],[t,n-f])}else{(this||u).paths.Left=new e.paths.Line([0,f],[0,n-f]);(this||u).paths.Right=new e.paths.Line([t,f],[t,n-f]);(this||u).paths.Bottom=new e.paths.Line([p,0],[t-p,0]);(this||u).paths.BottomLeft=new e.paths.Arc([l,c],r,h[0]-90,h[0]+90);(this||u).paths.BottomRight=new e.paths.Arc([t-l,c],r,h[1]-90,h[1]+90)}(this||u).paths.TopRight=new e.paths.Arc([t-l,n-c],r,h[2]-90,h[2]+90);(this||u).paths.TopLeft=new e.paths.Arc([l,n-c],r,h[3]-90,h[3]+90);(this||u).paths.Top=new e.paths.Line([p,n],[t-p,n])}return t}();t.Dogbone=n;n.metaParameters=[{title:"width",type:"range",min:1,max:100,value:50},{title:"height",type:"range",min:1,max:100,value:100},{title:"radius",type:"range",min:0,max:50,value:5},{title:"style",type:"select",value:[0,1,-1]},{title:"bottomless",type:"bool",value:false}]})(e.models||(e.models={}))})(c||(c={}));(function(e){(function(t){var n=function(){function t(t,n,r,a){(this||u).paths={};var i=t/2;r<0&&(r=0);r===void 0&&(r=i);r=Math.min(r,i);r=Math.min(r,n);var o=Math.max(i-r,0);var s=Math.max(n-r,0);a||((this||u).paths.Bottom=new e.paths.Line([-i,0],[i,0]));if(s){(this||u).paths.Left=new e.paths.Line([-i,0],[-i,s]);(this||u).paths.Right=new e.paths.Line([i,0],[i,s])}if(r>0){(this||u).paths.TopLeft=new e.paths.Arc([-o,s],r,90,180);(this||u).paths.TopRight=new e.paths.Arc([o,s],r,0,90)}o&&((this||u).paths.Top=new e.paths.Line([-o,n],[o,n]))}return t}();t.Dome=n;n.metaParameters=[{title:"width",type:"range",min:1,max:100,value:50},{title:"height",type:"range",min:1,max:100,value:100},{title:"radius",type:"range",min:0,max:50,value:25},{title:"bottomless",type:"bool",value:false}]})(e.models||(e.models={}))})(c||(c={}));(function(e){(function(t){var n=function(){function t(){var t=[];for(var n=0;n<arguments.length;n++)t[n]=arguments[n];(this||u).paths={};var r;var a;var i=0;switch(t.length){case 3:r=t[0];a=t[1];i=t[2];break;case 2:i=t[1];case 1:var o=e.measure.modelExtents(t[0]);(this||u).origin=e.point.subtract(o.low,[i,i]);r=o.high[0]-o.low[0]+2*i;a=o.high[1]-o.low[1]+2*i;break}var s=Math.min(a,r)/2;i=Math.min(i,s);var l=r-i;var c=a-i;if(i>0){(this||u).paths.BottomLeft=new e.paths.Arc([i,i],i,180,270);(this||u).paths.BottomRight=new e.paths.Arc([l,i],i,270,0);(this||u).paths.TopRight=new e.paths.Arc([l,c],i,0,90);(this||u).paths.TopLeft=new e.paths.Arc([i,c],i,90,180)}if(l-i>0){(this||u).paths.Bottom=new e.paths.Line([i,0],[l,0]);(this||u).paths.Top=new e.paths.Line([l,a],[i,a])}if(c-i>0){(this||u).paths.Right=new e.paths.Line([r,i],[r,c]);(this||u).paths.Left=new e.paths.Line([0,c],[0,i])}}return t}();t.RoundRectangle=n;n.metaParameters=[{title:"width",type:"range",min:1,max:100,value:50},{title:"height",type:"range",min:1,max:100,value:100},{title:"radius",type:"range",min:0,max:50,value:11}]})(e.models||(e.models={}))})(c||(c={}));(function(e){(function(e){var t=function(){function t(t,n){(this||u).paths={};(this||u).paths=new e.RoundRectangle(t,n,Math.min(n/2,t/2)).paths}return t}();e.Oval=t;t.metaParameters=[{title:"width",type:"range",min:1,max:100,value:50},{title:"height",type:"range",min:1,max:100,value:100}]})(e.models||(e.models={}))})(c||(c={}));(function(e){(function(t){var n=function(){function t(t,n,r,a,i,o){i===void 0&&(i=false);o===void 0&&(o=false);var s=this||u;(this||u).paths={};var l;if(o){l={models:{}};(this||u).models={Caps:l}}if(!(a<=0||r<=0)){t=e.angle.noRevolutions(t);n=e.angle.noRevolutions(n);if(e.round(t-n)!=0){n<t&&(n+=360);var c=function(t,n,i,u){var c;if(o){c={paths:{}};l.models[t]=c}else c=s;return c.paths[t]=new e.paths.Arc(e.point.fromPolar(e.angle.toRadians(n),r),a,n+i,n+u)};var p=function(a,i){return s.paths[a]=new e.paths.Arc([0,0],r+i,t,n)};p("Outer",a);var f=r-a>0;f&&p("Inner",-a);var h=[];h.push(c("StartCap",t,180,0));h.push(c("EndCap",n,0,180));var v=e.measure.pointDistance(h[0].origin,h[1].origin);if(v/2<a){var d=e.path.intersection(h[0],h[1]);if(d){if(!f||!i){h[0].startAngle=d.path1Angles[0];h[1].endAngle=d.path2Angles[0]}if(!i&&f&&d.intersectionPoints.length==2){c("StartCap2",t,180,0).endAngle=d.path1Angles[1];c("EndCap2",n,0,180).startAngle=d.path2Angles[1]+360}}}}}}return t}();t.OvalArc=n;n.metaParameters=[{title:"start angle",type:"range",min:-360,max:360,step:1,value:180},{title:"end angle",type:"range",min:-360,max:360,step:1,value:0},{title:"sweep",type:"range",min:0,max:100,step:1,value:50},{title:"radius",type:"range",min:0,max:100,step:1,value:15},{title:"self intersect",type:"bool",value:false}]})(e.models||(e.models={}))})(c||(c={}));(function(e){(function(t){var n=function(){function n(){var n=[];for(var r=0;r<arguments.length;r++)n[r]=arguments[r];(this||u).paths={};var a;var i;if(n.length!==2||e.isObject(n[0])){var o=0;var s;if(e.isModel(n[0])){s=e.measure.modelExtents(n[0]);n.length===2&&(o=n[1])}else s=n[0];(this||u).origin=e.point.subtract(s.low,[o,o]);a=s.high[0]-s.low[0]+2*o;i=s.high[1]-s.low[1]+2*o}else{a=n[0];i=n[1]}(this||u).paths=new t.ConnectTheDots(true,[[0,0],[a,0],[a,i],[0,i]]).paths}return n}();t.Rectangle=n;n.metaParameters=[{title:"width",type:"range",min:1,max:100,value:50},{title:"height",type:"range",min:1,max:100,value:100}]})(e.models||(e.models={}))})(c||(c={}));(function(e){(function(t){var n=function(){function t(t,n){(this||u).paths={};var r={Ring_outer:t,Ring_inner:n};for(var a in r){var i=r[a];i===void 0||i<=0||((this||u).paths[a]=new e.paths.Circle(e.point.zero(),i))}}return t}();t.Ring=n;n.metaParameters=[{title:"outer radius",type:"range",min:0,max:100,step:1,value:50},{title:"inner radius",type:"range",min:0,max:100,step:1,value:20}]})(e.models||(e.models={}))})(c||(c={}));(function(e){(function(t){var n=function(){function t(t,n,r){(this||u).paths={};var a=new e.paths.Arc([0,0],t,0,360);var i=new e.paths.Arc([n,0],r,0,360);var o=e.solvers.circleTangentAngles(a,i);if(o){o=o.sort((function(e,t){return e-t}));a.startAngle=o[0];a.endAngle=o[1];i.startAngle=o[1];i.endAngle=o[0];(this||u).paths.Left=a;(this||u).paths.Right=i;(this||u).paths.Top=new e.paths.Line(e.point.fromAngleOnCircle(o[0],a),e.point.fromAngleOnCircle(o[0],i));(this||u).paths.Bottom=new e.paths.Line(e.point.fromAngleOnCircle(o[1],a),e.point.fromAngleOnCircle(o[1],i))}else(this||u).paths.Belt=new e.paths.Circle(Math.max(t,r))}return t}();t.Belt=n;n.metaParameters=[{title:"left radius",type:"range",min:0,max:100,value:30},{title:"distance between centers",type:"range",min:0,max:100,value:50},{title:"right radius",type:"range",min:0,max:100,value:15}]})(e.models||(e.models={}))})(c||(c={}));(function(e){(function(t){var n=function(){function t(t,n){(this||u).paths={};function r(e,t){return e+(t*t-e*e)/(2*e)}var a=n/2;var i=t/2;var o;var s;var l;var c;if(t>n){o=r(a,i);s=270;l=360-e.angle.toDegrees(Math.acos(i/o));c=[0,o]}else{o=r(i,a);s=180-e.angle.toDegrees(Math.asin(a/o));l=180;c=[o,0]}var p=new e.paths.Arc(c,o,s,l);(this||u).paths.curve_start=p;(this||u).paths.curve_end=e.path.moveRelative(e.path.mirror(p,true,true),[t,n])}return t}();t.SCurve=n;n.metaParameters=[{title:"width",type:"range",min:1,max:100,value:50},{title:"height",type:"range",min:1,max:100,value:100}]})(e.models||(e.models={}))})(c||(c={}));(function(e){(function(t){var n=function(){function t(t,n,r,a){a===void 0&&(a=false);var i=this||u;(this||u).paths={};var o;if(a){o={models:{}};(this||u).models={Caps:o}}var s=function(e,t){var n;if(a){n={paths:{}};o.models[e]=n}else n=i;n.paths[e]=t};var l=e.angle.ofPointInDegrees(t,n);var c=e.measure.pointDistance(t,n);(this||u).paths.Top=new e.paths.Line([0,r],[c,r]);(this||u).paths.Bottom=new e.paths.Line([0,-r],[c,-r]);s("StartCap",new e.paths.Arc([0,0],r,90,270));s("EndCap",new e.paths.Arc([c,0],r,270,90));e.model.rotate(this||u,l,[0,0]);(this||u).origin=t}return t}();t.Slot=n;n.metaParameters=[{title:"origin",type:"select",value:[[0,0],[10,0],[10,10]]},{title:"end",type:"select",value:[[80,0],[0,30],[10,30]]},{title:"radius",type:"range",min:1,max:50,value:10}]})(e.models||(e.models={}))})(c||(c={}));(function(e){(function(e){var t=function(){function t(t){(this||u).paths={};(this||u).paths=new e.Rectangle(t,t).paths}return t}();e.Square=t;t.metaParameters=[{title:"side",type:"range",min:1,max:100,value:100}]})(e.models||(e.models={}))})(c||(c={}));(function(e){(function(e){var t=function(){function t(n,r,a,i){i===void 0&&(i=2);(this||u).paths={};a||(a=r*t.InnerRadiusRatio(n,i));var o=e.Polygon.getPoints(n,r);var s=e.Polygon.getPoints(n,a,180/n);var l=[];for(var c=0;c<n;c++){l.push(o[c]);l.push(s[c])}var p=new e.ConnectTheDots(true,l);(this||u).paths=p.paths;delete p.paths}t.InnerRadiusRatio=function(e,t){return e>0&&t>1&&t<e/2?Math.cos(Math.PI*t/e)/Math.cos(Math.PI*(t-1)/e):0};return t}();e.Star=t;t.metaParameters=[{title:"number of sides",type:"range",min:3,max:24,value:8},{title:"outer radius",type:"range",min:1,max:100,value:50},{title:"inner radius",type:"range",min:0,max:100,value:15},{title:"skip points (when inner radius is zero)",type:"range",min:0,max:12,value:2}]})(e.models||(e.models={}))})(c||(c={}));var c;(function(e){(function(t){var n=function(){
/**
       * Renders text in a given font to a model.
       * @param font OpenType.Font object or fontkit font object.
       * @param text String of text to render.
       * @param fontSize Font size.
       * @param combine Flag (default false) to perform a combineUnion upon each character with characters to the left and right.
       * @param centerCharacterOrigin Flag (default false) to move the x origin of each character to the center. Useful for rotating text characters.
       * @param bezierAccuracy Optional accuracy of Bezier curves.
       * @param opentypeOptions Optional opentype.RenderOptions object or fontkit layout options.
       * @returns Model of the text.
       */
function n(t,r,a,i,o,s,l){i===void 0&&(i=false);o===void 0&&(o=false);var c=this||u;(this||u).models={};var p=0;var f;var h;var v=function(r,a,u,l,v){var d=n.glyphToModel(r,l,s,t);d.origin=[a,0];if(o&&(d.paths||d.models)){var g=e.measure.modelExtents(d);if(g){var m=g.high[0]-g.low[0];e.model.originate(d,[g.low[0]+m/2,0])}}if(i&&p>0){var y={};var A;A=f?{models:{deleted:f,char:h}}:h;e.model.combine(A,d,false,true,false,true,y);f=y.out_deleted[1]}c.models[p]=d;p++;h=d};if(t.layout&&typeof t.layout==="function"){var d=t;var g=l;var m=d.layout(r,g===null||g===void 0?void 0:g.features,g===null||g===void 0?void 0:g.script,g===null||g===void 0?void 0:g.language,g===null||g===void 0?void 0:g.direction);var y=a/d.unitsPerEm;var A=0;for(var P=0;P<m.glyphs.length;P++){var w=m.glyphs[P];var T=m.positions[P];var x=A+(T.xOffset||0)*y;var C=(T.yOffset||0)*y;v(w,x,C,a,l);A+=(T.xAdvance||0)*y}}else{var b=t;b.forEachGlyph(r,0,0,a,l,v)}}
/**
       * Convert an opentype glyph or fontkit glyph to a model.
       * @param glyph Opentype.Glyph object or fontkit glyph.
       * @param fontSize Font size.
       * @param bezierAccuracy Optional accuracy of Bezier curves.
       * @param font Optional font object (needed for fontkit to get scale).
       * @returns Model of the glyph.
       */n.glyphToModel=function(r,a,i,o){var s={};var u;var l;var c=0;function p(e,t){s.paths||(s.paths={});t&&(s.layer||(s.layer=t));s.paths["p_"+ ++c]=e}function f(e,t){s.models||(s.models={});t&&(s.layer||(s.layer=t));s.models["p_"+ ++c]=e}var h=r.path&&!r.getPath;var v;if(h&&o){var d=a/o.unitsPerEm;v=r.path;if(r.layers&&r.layers.length>0){r.layers.forEach((function(r,a){var s=o.getGlyph(r.glyph);var u=s.path;if(u&&u.commands){var l=void 0;if(o.COLR&&o.CPAL&&r.color!==void 0){var c=o.CPAL;var h=c.colorPalettes||c.colorRecords;if(h&&h.length>0){var v=h[0];if(v&&v.length>r.color){var g=v[r.color];if(g){var m=g.red!==void 0?g.red:g.r||0;var y=g.green!==void 0?g.green:g.g||0;var A=g.blue!==void 0?g.blue:g.b||0;l="color_".concat(m.toString(16).padStart(2,"0")).concat(y.toString(16).padStart(2,"0")).concat(A.toString(16).padStart(2,"0"))}}}}var P=void 0;var w=void 0;for(var T=0,x=u.commands;T<x.length;T++){var C=x[T];var b=n.convertFontkitCommand(C,d);switch(C.command){case"moveTo":P=b[0];w=b[0];break;case"closePath":b[0]=P;case"lineTo":w&&!e.measure.isPointEqual(w,b[0])&&p(new e.paths.Line(w,b[0]),l);w=b[0];break;case"bezierCurveTo":w&&f(new t.BezierCurve(w,b[0],b[1],b[2],i),l);w=b[2];break;case"quadraticCurveTo":w&&f(new t.BezierCurve(w,b[0],b[1],i),l);w=b[1];break}}}}));return s}if(!v||!v.commands)return s;for(var g=0,m=v.commands;g<m.length;g++){var y=m[g];var A=n.convertFontkitCommand(y,d);switch(y.command){case"moveTo":u=A[0];l=A[0];break;case"closePath":A[0]=u;case"lineTo":e.measure.isPointEqual(l,A[0])||p(new e.paths.Line(l,A[0]));l=A[0];break;case"bezierCurveTo":f(new t.BezierCurve(l,A[0],A[1],A[2],i));l=A[2];break;case"quadraticCurveTo":f(new t.BezierCurve(l,A[0],A[1],i));l=A[1];break}}}else{v=r.getPath(0,0,a);v.commands.map((function(n,r){var a=[[n.x,n.y],[n.x1,n.y1],[n.x2,n.y2]].map((function(t){if(t[0]!==void 0)return e.point.mirror(t,false,true)}));switch(n.type){case"M":u=a[0];break;case"Z":a[0]=u;case"L":e.measure.isPointEqual(l,a[0])||p(new e.paths.Line(l,a[0]));break;case"C":f(new t.BezierCurve(l,a[1],a[2],a[0],i));break;case"Q":f(new t.BezierCurve(l,a[1],a[0],i));break}l=a[0]}))}return s};
/**
       * Convert fontkit path command to points array
       * @param cmd Fontkit path command
       * @param scale Scale factor
       * @returns Array of points
       */n.convertFontkitCommand=function(e,t){var n=[];switch(e.command){case"moveTo":case"lineTo":n.push([e.args[0]*t,e.args[1]*t]);break;case"quadraticCurveTo":n.push([e.args[0]*t,e.args[1]*t]);n.push([e.args[2]*t,e.args[3]*t]);break;case"bezierCurveTo":n.push([e.args[0]*t,e.args[1]*t]);n.push([e.args[2]*t,e.args[3]*t]);n.push([e.args[4]*t,e.args[5]*t]);break}return n};return n}();t.Text=n;n.metaParameters=[{title:"font",type:"font",value:"*"},{title:"text",type:"text",value:"Hello"},{title:"font size",type:"range",min:10,max:200,value:72},{title:"combine",type:"bool",value:false},{title:"center character origin",type:"bool",value:false}]})(e.models||(e.models={}))})(c||(c={}));c.version="0.19.2";var p=s;var f=l;export{f as default};

