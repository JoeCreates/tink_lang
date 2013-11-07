package tink.lang.macros;

import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
import tink.macro.ClassBuilder;
import tink.lang.macros.*;
import tink.core.Lazy;
using tink.MacroApi;
using StringTools;
using Lambda;

class LoopSugar {
	
	static function getVar(v:Expr):LoopVar 
		return { name: v.getIdent().sure(), pos: v.pos }	
		
	static function makeHead(v:LoopVar, target:LoopTarget, fallback:Null<Expr>):LoopHead 
		return { v: v, target: target, fallback: fallback }

	static function numeric(start, end, ?step, ?up = true) {
		if (step == null) step = macro 1;
		return Numeric(start, end, step, up);
	}
	static function parseSingle(e:Expr):LoopHead {
		function num(v, start, end, step, up, ?fallback)
			return makeHead(
				getVar(v), 
				numeric(start, end, step, up), 
				fallback
			);
			
		var fallback = null,
			step = null;
		return
			switch e {
				case macro $v += $step in $start...$end || $fallback:
					num(v, start, end, step, true, fallback);
				case macro $v += $step in $start...$end:
					num(v, start, end, step, true, fallback);
				case macro $v in $start...$end || $fallback:
					num(v, start, end, step, true, fallback);
				case macro $v in $start...$end:
					num(v, start, end, step, true, fallback);
				case macro $v -= $step in $start...$end || $fallback:
					num(v, start, end, step, false, fallback);
				case macro $v -= $step in $start...$end:
					num(v, start, end, step, false, fallback);
				case macro $e1 in $e2:
					makeHead(getVar(e1), Any(e2), null);
				default: 
					e.reject();
			}
	}
	static function parseHead(e:Expr) 
		return
			switch (e.expr) {
				case EArrayDecl(values):
					[for (v in values) parseSingle(v)];
				default: 
					[parseSingle(e)];
			}

	static function transform(it:Expr, expr:Expr) {
		var vars:Array<Var> = [];
		var single = true;
		var its = 
			switch it {
				case macro $a{many}: 
					single = false;
					many;
				case one: [one];
			}
		var body = 
			switch expr {
				case macro $b{many}: many;
				case one: [one];
			}
		//TODO: add support for key value iteration on arrays (?)
		its = 
			[for (it in its) 
				switch it {
					case macro $i{key} => $i{value} in $target:
						var tmp = MacroApi.tempName();
						vars.push({ name: tmp, expr: target, type: null });
						body.unshift(macro var $value = $i{tmp}.get($i{key}));
						macro $i{key} in @:pos(target.pos) $i{tmp}.keys();
					default: it;	
				}
			];
		
		expr = body.toBlock();
		
		var ret = 			
			switch its {
				case [macro $i{_} in $target] if (single):
					macro for (${its[0]}) $expr;
				default:
					it = its.toArray();	
					doTransform(it, expr);
			}
			
		return 
			if (vars.length > 0) {
				var vars = EVars(vars).at();
				macro { $vars; $ret; }
			}
			else ret;
	}
	static function doTransform(it:Expr, expr:Expr) {
		var loopFlag = temp('loop'),
			hasJump = false;
		
		var head = compileHeads(parseHead(it)),
			body = expr.transform(function (e:Expr) 
				return
					switch (e.expr) {
						case EBreak:
							hasJump = true;
							macro {
								$i{loopFlag} = false;
								continue;
							};
						case EContinue:
							hasJump = true;
							e;
						default: e;
					}
			);
		return 
			if (hasJump) 
				head.init.concat([
					loopFlag.define(macro true),
						EWhile(
							OpBoolAnd.make(loopFlag.resolve(), head.condition),
							head.beforeBody.concat([
							EWhile(
								if (Context.defined('java')) 
									macro Std.random(0) < 0
								else
									macro false,
								body,
								false
							).at()]).toBlock(),
							true
						).at()
				]).toBlock();
			else head.init.concat([
					EWhile(
						head.condition,
						head.beforeBody.concat([body]).toBlock(),
						true
					).at()
				]).toBlock();
	}	
	
	static public function temp(name:String) 
		return MacroApi.tempName('__tl_' + name);
		
	static function makeIterator(e:Expr) {
		function any() return [TPType(e.pos.makeBlankType())];
		return 
			if ((macro  $e.iterator()).is('Iterator'.asComplexType(any()))) 
				macro @:pos(e.pos) $e.iterator();
			else if (e.is('Iterator'.asComplexType(any()))) 
				e;
			else 
				e.pos.errorExpr('neither Iterable nor Iterator');
	}
	
	static function doInit(v:Expr, to:Expr) {
		var hasJump = false;
		v.transform(function (e) {
			if (e.expr == EContinue || e.expr == EBreak) hasJump = true;
			return e;
		});
		return
			if (to == null) null;
			else if (hasJump) v.assign(to);
			else 
				switch (to.expr) {
					case EBlock(exprs):
						exprs.push(doInit(v, exprs.pop()));
						to;
					case EIf(econd, eif, eelse), ETernary(econd, eif, eelse):
						EIf(econd, doInit(v, eif), doInit(v, eelse)).at(to.pos);
					default:
						v.assign(to);
				}
	}
	static function makeCompiledHead(v:LoopVar, init:Array<Expr>, hasNext:Expr, next:Expr, fallback:Null<Expr>, hasMandatory:Bool):CompiledHead {
		var beforeBody = [];
		if (fallback != null) {
			if (hasMandatory) {
				next = hasNext.cond(next, fallback);
				hasNext = macro true;//actually the condition pretty much doesn't matter here
			}
			else {
				var flag = temp('cond');
				init.push(flag.define(macro true));
				beforeBody.push(flag.resolve().cond(flag.resolve().assign(hasNext)));
				hasNext = flag.resolve();
				next = flag.resolve().cond(next, fallback);							
			}
		}
		beforeBody.push(v.name.define(v.t));
		beforeBody.push(doInit(v.name.resolve(), next));
		return {
			init: init,
			beforeBody: beforeBody,
			condition: hasNext
		}			
	}
	static function isConstNum(e:Expr)
		return
			switch (e.expr) {
				case EConst(c):
					switch (c) {
						case CFloat(_), CInt(_): true;
						default: false;
					}
				default: false;
			}
	
	static function standardIter(e:Expr) {
		var target = temp('target');
		var targetExpr = target.resolve(e.pos);
		
		return {
			init: [target.define(makeIterator(e), e.pos)], 
			hasNext: macro $targetExpr.hasNext(), 
			next: macro $targetExpr.next()
		}
	}
	static function getIterParts(e:Expr):CustomIter {
		var ret = FastLoops.iter(e);
		return
			if (ret == null) standardIter(e);
			else ret;
	}
	static var NOP = [].toBlock();
	static function lazily(f:Void->CompiledHead):CompiledHead {
		var l = Lazy.ofFunc(f);
		function map(h:CompiledHead->Expr):Expr 
			return (function () return h(l)).bounce();
		
		function getNthInit(n) 
			return map(function (h) {
				var ret = h.init[n];
				return 
					if (ret == null) NOP;
					else ret;
			});
		function getNthStep(n) 
			return map(function (h) {
				var ret = h.beforeBody[n];
				return 
					if (ret == null) NOP;
					else ret;
			});
		return {
			init: [for (i in 0...5) getNthInit(i)],
			beforeBody: [for (i in 0...5) getNthStep(i)],
			condition: map(function (h) return h.condition)
		}
	}
	static function compileHead(head:LoopHead, hasMandatory:Bool):CompiledHead {
		inline function make(init:Array<Expr>, hasNext:Expr, next:Expr)
			return makeCompiledHead(
				head.v, 
				init,
				hasNext,
				next,
				head.fallback, 
				hasMandatory
			);
			
		return
			switch (head.target) {
				case Any(e):
					lazily(function () return {
						var parts = getIterParts(e);
						head.v.t = e.getIterType().sure().toComplex();
						make(parts.init, parts.hasNext, parts.next);
					});
				case Numeric(start, end, step, up): //TODO: factor out this code
					lazily(function () return { 
						var intLoop = step.is(macro : Int);
						if (intLoop)
							for (e in [start, end])
								if (!e.is(macro : Int))
									e.reject('should be Int');
									
						var counterName = temp('counter');						
						var counter = counterName.resolve(),
							init = [];
							
						function mk(e:Expr, name:String) 
							return
								if (isConstNum(e)) e;
								else {
									name = temp(name);
									init.push(name.define(e, intLoop ? macro : Int : macro : Float, e.pos));
									name.resolve(e.pos);
								}
						
						step = mk(step, 'step');
						
						if (intLoop) {
							var counterInit = 
								if (up) {
									end = mk(macro $end - $step, 'end');
									macro $start - $step;
								}
								else {
									end = mk(end, 'end');
									if (step.getInt().equals(1)) start;
									else macro Math.ceil(($start - $end) / $step) * $step + $end;//this should be expressed with % for faster evaluation
								}
							init.push(counterName.define(counterInit));
							
							make(
								init,
								(up ? OpLt : OpGt).make(counter, end),
								if (up)
									macro $counter += $step
								else
									macro $counter -= $step
							);			
						}
						else {
							var counterEndName = temp('counterEnd');
							var counterEnd = counterEndName.resolve();
							
							if (up) {
								start = mk(start, 'start');
								
								init.push(counterName.define(macro 0));
								init.push(counterEndName.define(macro Math.ceil(($end - $start) / $step)));
								
								make(init, OpLt.make(counter, counterEnd), macro $counter++ * $step + $start);
							}
							else {
								end = mk(end, 'end');
								
								init.push(counterName.define(macro Math.ceil(($start - $end) / $step) - 1));
								
								make(init, OpGte.make(counter, macro 0), macro $counter-- * $step + $end);
							}
						}
					});
			}
	}
	static function compileHeads(heads:Array<LoopHead>):CompiledHead {
		var hasMandatory = false;
		for (head in heads)
			if (head.fallback == null) {
				hasMandatory = true;
				break;
			}
			
		var condition = hasMandatory.toExpr(),
			init = [],
			beforeBody = [];
			
		for (head in heads) {
			var c = compileHead(head, hasMandatory);
			
			init = init.concat(c.init);
			beforeBody = beforeBody.concat(c.beforeBody);
			
			if (hasMandatory) {
				if (head.fallback == null) 
					condition = OpBoolAnd.make(condition, c.condition);
			}
			else 
				condition = OpBoolOr.make(condition, c.condition);
		}
		if (!hasMandatory) {
			beforeBody.push(macro if (!$condition) break);
			condition = macro true;
		}
		return {
			init: init,
			beforeBody: beforeBody,
			condition: condition
		}
	}
	
	static public function comprehension(e:Expr) {
		function loop(it, body)
			return EFor(it, body).at(e.pos);
		
		function normalizePairLit(e:Expr) {
			var found = false;
			e = e.yield(function (e:Expr) return switch e {
				case macro $key => $val:
					found = true;
					'$'.resolve(e.pos).call([key, val], e.pos);
				case _: 
					e;
			});
			return new tink.core.Pair(found, e);
		}
		
		function comprehension(output:Expr, it:Expr, expr:Expr) {
			
			switch (output.getIdent()) {
				case Success(s): 
					if (s.startsWith('$')) return macro for ($it) $expr;//RAPTORS: hack to make sure this doesn't break tink_markup
				default:
			}
			
			var outputVarName = temp('output');
			var outputVar = outputVarName.resolve(output.pos);
			
			function getParams(e:Expr)
				return 
					switch (e.expr) {
						case ECall(callee, params):
							if (callee.getIdent().equals('$')) params;
							else [e];
						default: [e];
					}
					
			var returnOutput = false;		
			var doYield = 
				switch output {
					case macro $owner.$field:
						output = owner;
						returnOutput = true;
						var out = outputVar.field(field, owner.pos);
						function (e:Expr) 
							return out.call(getParams(e), e.pos);
					default:
						function (e:Expr)
							return outputVar.call(getParams(e), e.pos);
				}
				
			return [
				outputVarName.define(output, output.pos),
				loop(
					it, 
					expr.yield(doYield)
				),
				returnOutput ? outputVar : [].toBlock()
			].toBlock(e.pos);			
		}
		return 
			switch e {
				case macro [for ($it) $expr]:
					var n = normalizePairLit(expr);
					var output = 
						if (n.a) (macro @:pos(e.pos) new Map().set);
						else (macro @:pos(e.pos) [].push);
					comprehension(output, it, n.b);
				case macro $output(for ($it) $expr):
					comprehension(output, it, expr);
				default: e;
			}

		return e;
	}
	static public function transformLoop(e:Expr) {			
		return	
			switch (e.expr) {
				case EFor(it, expr):
					transform(it, expr);
				default: e;
			}
	}
	
}

typedef CompiledHead = {
	init: Array<Expr>,
	beforeBody: Array<Expr>,
	condition: Expr
}
typedef Loop = {
	head: LoopHead,
	body: Expr
}
typedef LoopVar = { 
	name: String, 
	pos:Position,
	?t:ComplexType
};
enum LoopTarget {
	Any(e:Expr);
	Numeric(start:Expr, end:Expr, step:Expr, up:Bool);
}
typedef LoopHead = {
	v:LoopVar,
	target:LoopTarget,
	fallback:Null<Expr>,
}