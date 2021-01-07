const assert = require("assert");

/**
 * Port from the equivalent function implemented in BinaryForeignArbitrationProxy.
 * This was extracted to make it easier to run tests against the algorithm.
 *
 * It is a slight variation of the Binary Search Rightmost algorithm:
 * https://en.wikipedia.org/wiki/Binary_search_algorithm#Procedure_for_finding_the_leftmost_element
 */
function findBestIndex(list, value) {
  if (list.length === 0 || list[0] > value) {
    throw new Error("Not found");
  }

  let left = 0;
  let right = list.length;

  if (value > list[right - 1]) {
    return right - 1;
  }

  while (left < right) {
    let pivot = Math.floor((left + right) / 2);
    if (list[pivot] <= value) {
      left = pivot + 1;
    } else {
      right = pivot;
    }
  }

  return right - 1;
}

describe("findBestIndex", () => {
  it("Should find the proper indexes", () => {
    {
      ("empty list");
      const list = [];
      const value = 11;

      assert.throws(() => findBestIndex(list, value), {message: "Not found"});
    }

    {
      ("single element list");
      const list = [10];
      const value = 11;
      const expected = 0;

      assert.equal(findBestIndex(list, value), expected);
    }

    {
      ("single element not found");
      const list = [20];
      const value = 11;

      assert.throws(() => findBestIndex(list, value), {message: "Not found"});
    }

    {
      const list = [0, 3, 10];
      const value = 11;
      const expected = 2;

      assert.equal(findBestIndex(list, value), expected);
    }

    {
      const list = [0, 3, 10];
      const value = 8;
      const expected = 1;

      assert.equal(findBestIndex(list, value), expected);
    }

    {
      const list = [0, 3, 10];
      const value = 2;
      const expected = 0;

      assert.equal(findBestIndex(list, value), expected);
    }

    {
      const list = [0, 3];
      const value = 2;
      const expected = 0;

      assert.equal(findBestIndex(list, value), expected);
    }

    {
      const list = [0, 3];
      const value = 10;
      const expected = 1;

      assert.equal(findBestIndex(list, value), expected);
    }

    {
      const list = [0, 3, 5, 10, 12];
      const value = 8;
      const expected = 2;

      assert.equal(findBestIndex(list, value), expected);
    }

    {
      const list = [0, 3, 5, 10, 12];
      const value = 10;
      const expected = 3;

      assert.equal(findBestIndex(list, value), expected);
    }

    {
      const list = [0, 3, 5, 10, 12];
      const value = 11;
      const expected = 3;

      assert.equal(findBestIndex(list, value), expected);
    }

    {
      const list = [1, 3, 5, 10, 12];
      const value = 0;

      assert.throws(() => findBestIndex(list, value), {message: "Not found"});
    }
  });
});
