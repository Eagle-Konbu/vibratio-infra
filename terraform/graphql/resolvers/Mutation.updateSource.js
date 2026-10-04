import { util } from '@aws-appsync/utils';

// Only the fields present in the input are updated.
export function request(ctx) {
  const { id, ...input } = ctx.args.input;
  const values = { ...input, updatedAt: util.time.nowISO8601() };

  const names = {};
  const expressionValues = {};
  const assignments = [];
  Object.keys(values)
    .filter((name) => values[name] !== null && values[name] !== undefined)
    .forEach((name) => {
      names[`#${name}`] = name;
      expressionValues[`:${name}`] = values[name];
      assignments.push(`#${name} = :${name}`);
    });

  return {
    operation: 'UpdateItem',
    key: util.dynamodb.toMapValues({ pk: 'SOURCE', sk: id }),
    update: {
      expression: `SET ${assignments.join(', ')}`,
      expressionNames: names,
      expressionValues: util.dynamodb.toMapValues(expressionValues),
    },
    condition: { expression: 'attribute_exists(pk)' },
  };
}

export function response(ctx) {
  if (ctx.error) {
    util.error(ctx.error.message, ctx.error.type);
  }
  return { ...ctx.result, id: ctx.result.sk };
}
