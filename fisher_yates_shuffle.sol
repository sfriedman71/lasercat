pragma solidity ^0.5.0;

contract SolidityTest {
   uint public storedData;

   uint[] public arr;
   uint public arraySize = 10;

   uint public randomNumber = 997654321;

   constructor() public{
      storedData = 10;

   }

   function initArray() public returns( uint ){
      arr = new uint[](arraySize);
      uint i = 0;

      while (i < arraySize ) {

        arr[i] = i + 1;
        i++;
      }
      return (i);
   }

   function shuffleArray() public returns( uint ){
      uint i = arr.length;
      uint temp;
      uint r;

      while (i > 1 ) {
        i--;
        temp = arr[i];
        r = randomNumber % i;
        arr[i] = arr[r];
        arr[r] = temp;

      }
      return (i);
   }


}
